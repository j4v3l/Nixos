import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const base = new URL('../home/quickshell/config/', import.meta.url);
function methods(path, context) {
    const source = fs.readFileSync(new URL(path, base), 'utf8');
    const functions = [...source.matchAll(/^    function (\w+)\((.*?)\) \{([\s\S]*?)^    \}/gm)];
    for (const [,name,args,body] of functions)
        context.root[name] = vm.runInNewContext(`(function(${args}) {${body}})`, context);
    return context.root;
}

const left = {name: 'DP-1'};
const right = {name: 'HDMI-A-1'};
const popup = methods('core/PopupManager.qml', {root: {screens: [left, right], focusedScreen: right, current: '', screenName: ''}});
popup.open('launcher', 0, 0);
assert.equal(popup.screenName, right.name, 'keyboard launches on the focused screen');
popup.toggle('launcher', 12, 20, left);
assert.equal(popup.screenName, left.name, 'same popup can move to another screen');
assert(popup.isOpen('launcher', left));
assert(!popup.isOpen('launcher', right));
popup.toggle('launcher', 12, 20, left);
assert.equal(popup.current, '');
popup.open('network', 100, 40, left);
popup.screens = [right];
popup.reconcileScreens();
assert.equal(popup.current, '', 'disconnect closes an anchored popup');

const cava = methods('services/CavaService.qml', {root: {consumers: {}}});
cava.setConsumer(left.name, true);
cava.setConsumer(right.name, true);
cava.setConsumer(left.name, false);
assert.deepEqual(Object.keys(cava.consumers), [right.name]);
cava.setConsumer(right.name, false);
assert.equal(Object.keys(cava.consumers).length, 0);

const writer = {running: false};
const clipboard = methods('services/ClipboardWriter.qml', {root: {queue: []}, writer});
const payloads = ['$(touch /tmp/never-execute)', '`printf bad`', 'quotes " \\ and\nnewlines', '${HOME}', 'second'];
clipboard.copy(payloads[0]);
assert.equal(clipboard.current, payloads[0]);
for (const payload of payloads.slice(1)) clipboard.copy(payload);
for (const payload of payloads.slice(1)) {
    writer.running = false;
    clipboard.next();
    assert.equal(clipboard.current, payload, 'clipboard preserves literal text in order');
}
const clipboardSource = fs.readFileSync(new URL('services/ClipboardWriter.qml', base), 'utf8');
assert.match(clipboardSource, /writer\.write\(root\.current\)/);
assert.doesNotMatch(clipboardSource, /"sh"|"bash"|JSON\.stringify/);
assert.match(clipboardSource, /command: \["wl-copy"/);
console.log('PASS: popup routing, hotplug, shared audio lifecycle, and literal clipboard queue');

const actionProcess = {running: false};
const history = methods('services/ClipboardService.qml', {root: {operations: []}, actionProcess});
history.enqueue('paste', payloads[0]);
assert.equal(history.operation.raw, payloads[0]);
assert.deepEqual(Array.from(actionProcess.command), ['bash', '-o', 'pipefail', '-c', 'cliphist decode | wl-copy']);
history.enqueue('delete', payloads[2]);
actionProcess.running = false;
history.nextOperation();
assert.equal(history.operation.raw, payloads[2]);
assert.deepEqual(Array.from(actionProcess.command), ['cliphist', 'delete']);
const historySource = fs.readFileSync(new URL('services/ClipboardService.qml', base), 'utf8');
assert.match(historySource, /actionProcess\.write\(root\.operation\.raw \+ "\\n"\)/);
assert.doesNotMatch(historySource, /shellQuote|JSON\.stringify/);
console.log('PASS: clipboard history sends external text through stdin');
