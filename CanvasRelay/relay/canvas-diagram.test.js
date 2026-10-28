'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {canvasMermaid,canvasDiagramMarkdown} = require('./canvas-diagram');
const a='11111111-1111-4111-8111-111111111111', b='22222222-2222-4222-8222-222222222222';
const edge='33333333-3333-4333-8333-333333333333';
const scene = () => ({nodes:[{id:a,text:'계획 👩🏽‍💻'},{id:b,text:'완료'}],
  links:[{id:edge,from:a,to:b,label:'검토',kind:'parentChild'}]});

test('같은 노드 UUID와 관계를 Mermaid로 도출하고 원본을 바꾸지 않는다', () => {
  const value=scene(), before=JSON.stringify(value);
  assert.equal(canvasMermaid(value),`flowchart TD\nn${a.replaceAll('-','')}["계획 👩🏽‍💻"]\nn${b.replaceAll('-','')}["완료"]\nn${a.replaceAll('-','')} -->|"검토"| n${b.replaceAll('-','')}`);
  value.nodes[0].text='수정한 글자';
  assert.ok(canvasMermaid(value).includes('수정한 글자'));
  assert.equal(JSON.stringify(scene()),before);
});

test('접힌 하위 요소와 관계를 숨기고 손상된 구조나 한도 초과는 표시하지 않는다', () => {
  const value=scene();value.nodes[0].isCollapsed=true;
  assert.equal(canvasMermaid(value).split('\n').length,2);
  value.nodes.push({...value.nodes[0],id:a.toUpperCase()});
  assert.equal(canvasMermaid(value),null);
  const large=scene();large.nodes[0].text='한'.repeat(20000);
  assert.equal(canvasMermaid(large),null);
  assert.ok(canvasDiagramMarkdown(large).includes('보존됩니다'));
});

test('노드 본문이 코드 블록·Mermaid 명령·HTML로 탈출하지 않는다', () => {
  const value=scene();value.nodes[0].text='"\n```\nclick bad "javascript:alert(1)"\n<script>';
  const source=canvasMermaid(value);
  assert.equal(source.split('\n').length,4);
  assert.ok(!source.includes('```'));
  assert.ok(!source.includes('<script>'));
  assert.ok(source.includes('#10;'));
});

test('실제 Swift 도출 결과와 UTF-8 바이트가 같다', {skip:!process.env.CCR_PELE_SWIFT_OUTPUT}, () => {
  const root=process.env.CCR_PELE_SWIFT_OUTPUT;
  const value=JSON.parse(fs.readFileSync(root+'/edited-scene.json','utf8'));
  const snapshots=JSON.parse(fs.readFileSync(root+'/snapshots.json','utf8'));
  assert.deepEqual(Buffer.from(canvasMermaid(value)),Buffer.from(snapshots[1].source));
});
