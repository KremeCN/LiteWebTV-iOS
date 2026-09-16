'use strict';

var assert = require('assert');
var compat = require('../LiteWebTV/Resources/cctv_sw_compat.js');

var CCTV4 = 'https://tv.cctv.com/live/cctv4/m/';
var CCTV2 = 'https://tv.cctv.com/live/cctv2/m/';
var CCTV5PLUS = 'https://tv.cctv.com/live/cctv5plus/m/';
var SCRIPT = '/Library/ios.cdrm.sw.base.js';
var ORIGIN = 'https://tv.cctv.com';

assert.strictEqual(compat.shouldRewrite(SCRIPT, { scope: '../' }, CCTV4), true);
assert.strictEqual(compat.shouldRewrite(SCRIPT, { scope: '../' }, CCTV5PLUS), true);
assert.strictEqual(compat.shouldRewrite(SCRIPT, { scope: '/live/' }, CCTV4), true);
assert.strictEqual(compat.shouldRewrite(SCRIPT, { scope: '../' }, CCTV2), true);
assert.strictEqual(compat.shouldRewrite(SCRIPT, undefined, CCTV4), false);
assert.strictEqual(compat.shouldRewrite(SCRIPT, { scope: '/' }, CCTV4), false);
assert.strictEqual(compat.shouldRewrite('/other.js', { scope: '../' }, CCTV4), false);
assert.strictEqual(compat.shouldRewrite(SCRIPT, { scope: '../' }, 'https://www.yangshipin.cn/tv/home'), false);
assert.strictEqual(compat.shouldRewrite(SCRIPT, { scope: '../' }, 'https://tv.cctv.com/other/'), false);

assert.strictEqual(compat.isLegacyChannelScope('https://tv.cctv.com/live/cctv4/', ORIGIN), true);
assert.strictEqual(compat.isLegacyChannelScope('https://tv.cctv.com/live/cctv5plus/', ORIGIN), true);
assert.strictEqual(compat.isLegacyChannelScope('https://tv.cctv.com/live/', ORIGIN), false);
assert.strictEqual(compat.isLegacyChannelScope('https://tv.cctv.com/', ORIGIN), false);
assert.strictEqual(compat.isOfficialWorkerScript('https://tv.cctv.com/Library/ios.cdrm.sw.base.js', ORIGIN), true);
assert.strictEqual(compat.isOfficialWorkerScript('https://tv.cctv.com/other.js', ORIGIN), false);

var copied = compat.copyOptions({ scope: '../', updateViaCache: 'none' });
assert.strictEqual(copied.scope, '/live/');
assert.strictEqual(copied.updateViaCache, 'none');

function fakeReg(scope, script, shouldUnregister) {
    var unregistered = false;
    return {
        scope: scope,
        active: script ? { scriptURL: script } : null,
        waiting: null,
        installing: null,
        unregistered: function () { return unregistered; },
        unregister: function () {
            if (shouldUnregister === false) {
                throw new Error('should not unregister');
            }
            unregistered = true;
            return Promise.resolve(true);
        }
    };
}

var official = 'https://tv.cctv.com/Library/ios.cdrm.sw.base.js';
var otherWorker = 'https://tv.cctv.com/other.sw.js';
var legacy2 = fakeReg('https://tv.cctv.com/live/cctv2/', official);
var legacy4 = fakeReg('https://tv.cctv.com/live/cctv4/', official);
var shared = fakeReg('https://tv.cctv.com/live/', official, false);
var foreign = fakeReg('https://tv.cctv.com/live/cctv1/', otherWorker, false);

compat.migrateLegacyRegistrations({
    origin: function () { return ORIGIN; },
    getRegistrations: function () { return [legacy2, legacy4, shared, foreign]; }
}).then(function (stats) {
    assert.deepStrictEqual(stats, { scanned: 4, matched: 2, unregistered: 2 });
    assert.strictEqual(legacy2.unregistered(), true);
    assert.strictEqual(legacy4.unregistered(), true);
    assert.strictEqual(shared.unregistered(), false);
    assert.strictEqual(foreign.unregistered(), false);
}).then(function () {
    var calls = [];
    var posts = [];
    var gen = 0;
    var wrapper = compat.createRegisterWrapper(function (scriptURL, options) {
        calls.push({ thisValue: this, scriptURL: scriptURL, options: options });
        return Promise.resolve({ ok: true, options: options });
    }, {
        href: function () { return CCTV4; },
        origin: function () { return ORIGIN; },
        generation: function () { return gen; },
        getRegistrations: function () { return [legacy2, shared]; },
        post: function (data) { posts.push(data); }
    });
    var ctx = { label: 'container' };
    return wrapper.call(ctx, SCRIPT, { scope: '../' }).then(function (result) {
        assert.strictEqual(result.ok, true);
        assert.strictEqual(calls.length, 1);
        assert.strictEqual(calls[0].thisValue, ctx);
        assert.strictEqual(calls[0].scriptURL, SCRIPT);
        assert.strictEqual(calls[0].options.scope, '/live/');
        assert.strictEqual(posts[0].phase, 'migrate');
        assert.strictEqual(posts[1].phase, 'register-ok');
    });
}).then(function () {
    var called = false;
    var wrapper = compat.createRegisterWrapper(function (scriptURL, options) {
        called = true;
        return 'passthrough:' + scriptURL + ':' + (options && options.scope);
    }, {
        href: function () { return CCTV4; },
        origin: function () { return ORIGIN; },
        generation: function () { return 0; },
        getRegistrations: function () { throw new Error('migrate should not run'); },
        post: function () { throw new Error('post should not run'); }
    });
    var result = wrapper.call({}, '/ads.sw.js', { scope: '../' });
    assert.strictEqual(called, true);
    assert.strictEqual(result, 'passthrough:/ads.sw.js:../');
}).then(function () {
    var posts = [];
    var wrapper = compat.createRegisterWrapper(function () {
        var err = new Error('Job rejected for non app-bound domain');
        err.name = 'TypeError';
        return Promise.reject(err);
    }, {
        href: function () { return CCTV4; },
        origin: function () { return ORIGIN; },
        generation: function () { return 0; },
        getRegistrations: function () { return []; },
        post: function (data) { posts.push(data); }
    });
    return wrapper.call({}, SCRIPT, { scope: '../' }).then(function () {
        throw new Error('expected register rejection');
    }, function (err) {
        assert.strictEqual(err.name, 'TypeError');
        assert.strictEqual(posts[1].phase, 'register-fail');
        assert.strictEqual(posts[1].name, 'TypeError');
        assert.ok(posts[1].message.indexOf('Job rejected') !== -1);
    });
}).then(function () {
    var registerCalled = false;
    var gen = 0;
    var wrapper = compat.createRegisterWrapper(function () {
        registerCalled = true;
        return Promise.resolve({});
    }, {
        href: function () { return CCTV4; },
        origin: function () { return ORIGIN; },
        generation: function () { return gen; },
        getRegistrations: function () {
            gen += 1;
            return [];
        },
        post: function () { }
    });
    return wrapper.call({}, SCRIPT, { scope: '../' }).then(function () {
        throw new Error('expected stale rejection');
    }, function (err) {
        assert.strictEqual(err.name, 'InvalidStateError');
        assert.strictEqual(registerCalled, false);
    });
}).then(function () {
    var calls = [];
    var posts = [];
    var wrapper = compat.createRegisterWrapper(function (scriptURL, options) {
        calls.push(options.scope);
        return Promise.resolve({ ok: true });
    }, {
        href: function () { return CCTV4; },
        origin: function () { return ORIGIN; },
        generation: function () { return 0; },
        getRegistrations: function () { return Promise.reject(new Error('enumerate failed')); },
        post: function (data) { posts.push(data); }
    });
    return wrapper.call({}, SCRIPT, { scope: '../' }).then(function () {
        assert.deepStrictEqual(calls, ['/live/']);
        assert.strictEqual(posts[0].phase, 'migrate-error');
        assert.strictEqual(posts[1].phase, 'migrate');
        assert.strictEqual(posts[2].phase, 'register-ok');
    });
}).then(function () {
    console.log('cctv_sw_compat tests passed');
}).catch(function (err) {
    console.error(err);
    process.exit(1);
});
