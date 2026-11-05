'use strict';
const assert = require('node:assert/strict');
const {createHash, randomUUID} = require('node:crypto');

// The caller supplies the exact pinned authority module; this fixture uses memory only.
module.exports = function checkNativeAuthority({audioForwardingAuthority}) {
  const hashes = [
    'f9ad2dcbdbb7cc56768603bc5a05935bd613fa71dea4c53419a8dc13d2da0ff2',
    'c58ba9f8033a8b8194c8dd91b77fd0ed675b4fadb52eeeb5926ada373cffedbd'
  ];
  let checks = 0;
  const equal = (actual, expected) => { assert.deepEqual(actual, expected); checks++; };
  const rejects = (action, code) => {
    assert.throws(action, error => error.code === code); checks++;
  };
  function fixture() {
    let saved, time = 0;
    const authority = audioForwardingAuthority({
      store:{load:() => saved && structuredClone(saved), save:value => {
        saved = structuredClone(value); return true;
      }},
      credentialKey:Buffer.alloc(32, 42), now:() => time,
      setTimer:() => ({unref(){}}), cancelTimer(){}
    });
    const id = createHash('sha256').update('native-provider-fixture').digest('hex');
    const generation = randomUUID(), connectionId = randomUUID();
    const credential = authority.registerDevice(id, generation).credential;
    authority.updateEvidence({pairedDeviceId:id, pairingGeneration:generation, connectionId, operation:'attach'});
    const configuration = {controllerBootId:randomUUID(), privacyGeneration:randomUUID(), registryRevision:'1',
      members:[{participantId:'native.sill', bootId:randomUUID()},
        {participantId:'s23.audio.relay', bootId:randomUUID()}]};
    authority.configure(configuration);
    const preparation = authority.preflight(id, credential, {schemaVersion:1, pairedDeviceId:id,
      intentId:randomUUID(), intentRevision:'1', action:'request', inputDesired:true, outputDesired:true,
      expectedRevision:authority.snapshot().revision, transportId:randomUUID(), transportKind:'native', bindingRevision:'1'});
    const facts = Object.fromEntries(['admissionFenced','startsSettled','mediaDetached',
      'callbacksDrained','buffersEmpty','workersExited'].map(key => [key,true]));
    const receipts = configuration.members.map(member => ({...member, schemaVersion:1,
      operationId:preparation.binding.operationId, privacyGeneration:configuration.privacyGeneration,
      registryRevision:'1', state:'quiescent', facts}));
    const snapshot = authority.commit({intentGeneration:preparation.intent.intentGeneration,
      bindingEpoch:preparation.binding.bindingEpoch, operationId:preparation.binding.operationId,
      configuration, receipts, localProtection:{sentryVerified:false,localMutedVerified:true}}, receipts[1]);
    const request = {requestId:randomUUID(), action:'start', expectedLeaseRevision:snapshot.revision,
      pairedDeviceId:id, desiredInput:true, desiredOutput:true, callSessionId:null};
    const acquire = targetHash => ({pairedDeviceId:id, credential, request, targetHash,
      intentGeneration:snapshot.intent.intentGeneration, bindingEpoch:snapshot.binding.bindingEpoch});
    const follow = (scope, targetHash) => ({pairedDeviceId:id,credential, requestId:request.requestId,
      scopeId:scope.scopeId,nodeGeneration:scope.nodeGeneration,
      expectedLeaseRevision:request.expectedLeaseRevision,targetHash});
    return {authority, acquire, follow, expire:() => {time = 1501;}, detach:() =>
      authority.updateEvidence({pairedDeviceId:id,pairingGeneration:generation,connectionId,operation:'detach'})};
  }
  for (const hash of hashes) {
    const f = fixture(), scope = f.authority.providerAcquire(f.acquire(hash));
    equal(scope.state, 'prepared');
    rejects(() => f.authority.providerAcquire(f.acquire(hash === hashes[0] ? hashes[1] : hashes[0])), 'provider_request_conflict');
    rejects(() => f.authority.providerDispatch(f.follow(scope, hash === hashes[0] ? hashes[1] : hashes[0])), 'provider_scope_mismatch');
    const follow = f.follow(scope, hash);
    equal(f.authority.providerDispatch(follow).state, 'dispatch_authorized');
    equal(f.authority.providerDispatch(follow).state, 'recorded');
    equal(f.authority.providerRelease({...follow,outcome:'dispatched'}).outcome, 'dispatched');
    equal(f.authority.providerDispatch(follow).state, 'recorded');
    f.authority.loseController();
  }
  {
    const f = fixture(), scope = f.authority.providerAcquire(f.acquire(hashes[0]));
    f.expire();
    equal(f.authority.providerDispatch(f.follow(scope,hashes[0])).state,'recorded');
    f.authority.loseController();
  }
  {
    const f = fixture(), scope = f.authority.providerAcquire(f.acquire(hashes[0]));
    f.detach();
    rejects(() => f.authority.providerDispatch(f.follow(scope,hashes[0])), 'device_evidence_unavailable');
    f.authority.loseController();
  }
  return {checks, failures:0, fixtureOnly:true, realCallStarted:false,
    mediaProtectionAttested:false, deviceOrHALCommands:0};
};
