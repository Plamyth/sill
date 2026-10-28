'use strict';
const crypto = require('node:crypto');
const os = require('node:os');
const path = require('node:path');
const {ControlEventsClient} = require('./vendor/control-events/control-events-client');
const {SCHEMA,diffSnapshot,encode} = require('./vendor/control-events/control-events');
const {controlRoomProjection} = require('./control-room-projection');
const {controlRoomSources} = require('./control-room-sources');

const SOCKET = path.join(os.homedir(),'Library','Application Support','CodexControlRoom','control-events.sock');
const MAX_JSON_BYTES = 8*1024*1024-8192;

function frame(event) {
  const data = encode(event).slice(0,-1);
  if (Buffer.byteLength(data) > MAX_JSON_BYTES) throw new Error('iPad 관제 이벤트가 8 MiB 전송 한도를 초과했습니다.');
  return `id: ${event.generation}:${event.revision}\nevent: ${event.type}\ndata: ${data}\n\n`;
}

class ControlRoomEvents {
  constructor({readHiddenIds, socketPath = SOCKET, now = Date.now, heartbeatMs = 15000,
    retryMs = 250, maxRetryMs = 10000, backpressureMs = 30000, projectSources = controlRoomSources,
    subscribePolicy = () => () => {}} = {}) {
    this.now = now;
    this.readHiddenIds = readHiddenIds;
    this.projectSources = projectSources;
    this.subscribePolicy = subscribePolicy;
    this.policySubscription = null;
    this.closed = false;
    this.generation = crypto.randomUUID();
    this.revision = 0;
    this.snapshot = {schemaVersion:1,threads:[],catalog:[],sourceObservedAt:null,
      connection:{connected:false,state:'unavailable'}};
    this.upstreamGeneration = null;
    this.sourceSnapshot = null;
    this.sourceClock = null;
    this.clients = new Map();
    this.backpressureMs = backpressureMs;
    this.heartbeatMs = heartbeatMs;
    this.timer = null;
    this.client = new ControlEventsClient({socketPath,retryMs,maxRetryMs,
      onSnapshot:(snapshot,identity) => this.apply(snapshot,identity),
      onConnection:({connected}) => { if (!connected) this.disconnect(); }});
  }

  event(type, fields = {}) {
    return {schema:SCHEMA,type,generation:this.generation,revision:this.revision,
      emittedAt:new Date(this.now()).toISOString(),...fields};
  }

  send(response, event, encoded) {
    const consumer = this.clients.get(response);
    if (!consumer || consumer.initializing) return;
    if (response.destroyed || response.writableEnded) return response.destroy();
    if (consumer.blocked) {
      if (event.type !== 'heartbeat') consumer.pending = true;
      return;
    }
    if (!response.write(encoded ?? frame(event))) {
      consumer.blocked = true;
      consumer.timer = setTimeout(() => response.destroy(),this.backpressureMs);
      consumer.timer.unref();
    }
  }

  publish(next, full = false) {
    if (!full && JSON.stringify(next) === JSON.stringify(this.snapshot)) return;
    const patch = diffSnapshot(this.snapshot,next);
    const event = this.event(full ? 'snapshot' : 'patch',full ? {snapshot:next} :
      {baseRevision:this.revision,...patch});
    event.revision++;
    frame(this.event('snapshot',{revision:event.revision,snapshot:next}));
    const encoded = frame(event);
    this.revision = event.revision;
    this.snapshot = next;
    for (const response of this.clients.keys()) this.send(response,event,encoded);
  }

  unavailable() {
    this.publish({schemaVersion:1,threads:[],catalog:[],sourceObservedAt:this.snapshot.sourceObservedAt,
      connection:{connected:false,state:'unavailable'}});
  }

  policy() {
    try { return this.readHiddenIds(); }
    catch { this.unavailable(); return null; }
  }

  refreshPolicy() {
    const hidden = this.policy();
    if (hidden === null || this.sourceSnapshot === null) return;
    try {
      const projection = controlRoomProjection(this.sourceSnapshot,this.sourceClock,hidden);
      const sources = this.projectSources(this.sourceSnapshot,hidden,this.sourceClock);
      this.publish({...projection,...sources,threads:[],catalog:[],sourceObservedAt:projection.generatedAt,
        connection:this.snapshot.connection});
    } catch { this.unavailable(); }
  }

  stopPolicy() {
    const subscription = this.policySubscription;
    this.policySubscription = null;
    subscription?.unsubscribe?.();
  }

  startPolicy() {
    if (this.policySubscription) return true;
    const subscription = {unsubscribe:null};
    this.policySubscription = subscription;
    const onError = () => {
      if (this.policySubscription !== subscription) return;
      this.stopPolicy();
      this.unavailable();
      this.client.close();
      for (const response of this.clients.keys()) {
        const consumer = this.clients.get(response);
        if (consumer?.initializing) {
          consumer.initializing = false;
          this.send(response,this.event('snapshot',{snapshot:this.snapshot}));
        }
        if (response.end) response.end();
        else response.destroy();
      }
    };
    try {
      const unsubscribe = this.subscribePolicy({onInvalidate:() => {
        if (this.policySubscription === subscription) this.refreshPolicy();
      },onError});
      if (this.policySubscription !== subscription || this.closed || !this.clients.size) {
        unsubscribe();
        return false;
      }
      subscription.unsubscribe = unsubscribe;
      return true;
    } catch {
      onError();
      return false;
    }
  }

  apply(snapshot, identity) {
    const hidden = this.policy();
    if (hidden === null) return;
    try {
      const clock = this.now();
      const projection = controlRoomProjection(snapshot,clock,hidden);
      const sources = this.projectSources(snapshot,hidden,clock);
      const next = {...projection,...sources,threads:[],catalog:[],sourceObservedAt:projection.generatedAt,
        connection:{connected:true,state:'connected'}};
      this.publish(next,this.upstreamGeneration !== identity.generation);
      this.upstreamGeneration = identity.generation;
      this.sourceSnapshot = snapshot;
      this.sourceClock = clock;
    } catch {
      this.disconnect();
      this.refreshPolicy();
    }
  }

  disconnect() {
    this.publish({...this.snapshot,connection:{connected:false,
      state:this.snapshot.connection.state === 'unavailable' || this.snapshot.sourceObservedAt === null ?
        'unavailable' : 'stale'}});
  }

  heartbeat() {
    const event = this.event('heartbeat');
    for (const response of this.clients.keys()) this.send(response,event);
  }

  attach(response) {
    if (this.closed) return response.destroy();
    response.writeHead(200,{'content-type':'text/event-stream; charset=utf-8',
      'cache-control':'no-store','x-accel-buffering':'no'});
    const consumer = {initializing:true,blocked:false,pending:false,timer:null};
    this.clients.set(response,consumer);
    response.once('close',() => {
      clearTimeout(consumer.timer);
      this.clients.delete(response);
      if (!this.clients.size) {
        this.stopPolicy();
        clearInterval(this.timer);
        this.timer = null;
        this.client.close();
        this.disconnect();
      }
    });
    response.on('drain',() => {
      if (!this.clients.has(response)) return;
      clearTimeout(consumer.timer);
      if (!consumer.pending) { consumer.blocked = false; return; }
      this.refreshPolicy();
      consumer.blocked = false;
      consumer.pending = false;
      this.send(response,this.event('snapshot',{snapshot:this.snapshot}));
    });
    if (!this.clients.has(response) || !this.startPolicy() || this.closed || !this.clients.size) return;
    this.refreshPolicy();
    consumer.initializing = false;
    this.send(response,this.event('snapshot',{snapshot:this.snapshot}));
    if (this.closed || !this.clients.has(response) || !this.policySubscription) return;
    if (!this.timer) {
      this.timer = setInterval(() => this.heartbeat(),this.heartbeatMs);
      this.timer.unref();
    }
    this.client.start();
  }

  close() {
    this.closed = true;
    this.stopPolicy();
    clearInterval(this.timer);
    this.timer = null;
    this.client.close();
    for (const response of this.clients.keys()) response.destroy();
    this.clients.clear();
    this.sourceSnapshot = null;
    this.sourceClock = null;
  }
}

module.exports = {ControlRoomEvents,MAX_JSON_BYTES};
