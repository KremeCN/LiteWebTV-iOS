(function (root) {
    'use strict';

    var OFFICIAL_SCRIPT = '/Library/ios.cdrm.sw.base.js';
    var SHARED_SCOPE = '/live/';
    var LEGACY_SCOPE = /^\/live\/[A-Za-z0-9_-]+\/$/;

    function describeRegister(scriptURL, options, href) {
        var page = new URL(href);
        var script = new URL(String(scriptURL), href);
        var scope;
        if (options && options.scope != null && String(options.scope) !== '') {
            scope = new URL(String(options.scope), href);
        } else {
            scope = new URL('./', script);
        }
        return { page: page, script: script, scope: scope };
    }

    function isOfficialPage(page) {
        return page.hostname === 'tv.cctv.com' && page.pathname.indexOf('/live/') === 0;
    }

    function isOfficialScript(script, page) {
        return script.origin === page.origin && script.pathname === OFFICIAL_SCRIPT;
    }

    function isLivePlayerScope(scope, page) {
        if (scope.origin !== page.origin) return false;
        if (scope.pathname === SHARED_SCOPE) return true;
        return LEGACY_SCOPE.test(scope.pathname);
    }

    function shouldRewrite(scriptURL, options, href) {
        try {
            var desc = describeRegister(scriptURL, options, href);
            return isOfficialPage(desc.page) && isOfficialScript(desc.script, desc.page) && isLivePlayerScope(desc.scope, desc.page);
        } catch (e) {
            return false;
        }
    }

    function isOfficialWorkerScript(scriptURL, origin) {
        try {
            var script = new URL(scriptURL);
            return script.origin === origin && script.pathname === OFFICIAL_SCRIPT;
        } catch (e) {
            return false;
        }
    }

    function isLegacyChannelScope(scopeURL, origin) {
        try {
            var scope = new URL(scopeURL);
            return scope.origin === origin && LEGACY_SCOPE.test(scope.pathname);
        } catch (e) {
            return false;
        }
    }

    function copyOptions(options) {
        var next = {};
        if (options && typeof options === 'object') {
            for (var key in options) {
                if (Object.prototype.hasOwnProperty.call(options, key)) {
                    next[key] = options[key];
                }
            }
        }
        next.scope = SHARED_SCOPE;
        return next;
    }

    function errorSnapshot(err) {
        return {
            name: err && err.name ? String(err.name) : 'Error',
            message: err && err.message ? String(err.message).slice(0, 80) : ''
        };
    }

    function invalidStateError() {
        try {
            return new DOMException('The object is in an invalid state.', 'InvalidStateError');
        } catch (e) {
            var err = new Error('The object is in an invalid state.');
            err.name = 'InvalidStateError';
            return err;
        }
    }

    function migrateLegacyRegistrations(env) {
        return Promise.resolve(env.getRegistrations()).then(function (regs) {
            if (!regs || !regs.length) {
                return { scanned: 0, matched: 0, unregistered: 0 };
            }
            var origin = env.origin();
            var matched = [];
            for (var i = 0; i < regs.length; i++) {
                var reg = regs[i];
                var worker = reg.active || reg.waiting || reg.installing;
                var scriptURL = worker && worker.scriptURL ? String(worker.scriptURL) : '';
                if (!isOfficialWorkerScript(scriptURL, origin)) continue;
                if (!isLegacyChannelScope(reg.scope, origin)) continue;
                matched.push(reg);
            }
            return Promise.all(matched.map(function (reg) {
                return Promise.resolve().then(function () {
                    return reg.unregister();
                }).then(function (ok) {
                    return ok ? 1 : 0;
                }).catch(function () {
                    return 0;
                });
            })).then(function (results) {
                var unregistered = 0;
                for (var j = 0; j < results.length; j++) unregistered += results[j];
                return { scanned: regs.length, matched: matched.length, unregistered: unregistered };
            });
        });
    }

    function createRegisterWrapper(originalRegister, env) {
        return function (scriptURL, options) {
            if (!shouldRewrite(scriptURL, options, env.href())) {
                return originalRegister.apply(this, arguments);
            }
            var self = this;
            var gen = env.generation();
            return Promise.resolve()
                .then(function () {
                    return migrateLegacyRegistrations(env);
                })
                .catch(function (err) {
                    var fail = errorSnapshot(err);
                    env.post({
                        phase: 'migrate-error',
                        name: fail.name,
                        message: fail.message,
                        scanned: 0,
                        matched: 0,
                        unregistered: 0,
                        scope: SHARED_SCOPE
                    });
                    return { scanned: 0, matched: 0, unregistered: 0 };
                })
                .then(function (stats) {
                    env.post({
                        phase: 'migrate',
                        scanned: stats.scanned,
                        matched: stats.matched,
                        unregistered: stats.unregistered,
                        scope: SHARED_SCOPE
                    });
                    if (env.generation() !== gen) {
                        env.post({
                            phase: 'stale-document',
                            scanned: stats.scanned,
                            matched: stats.matched,
                            unregistered: stats.unregistered,
                            scope: SHARED_SCOPE
                        });
                        return Promise.reject(invalidStateError());
                    }
                    var nextOptions = copyOptions(options);
                    try {
                        var result = originalRegister.call(self, scriptURL, nextOptions);
                        return Promise.resolve(result).then(function (registration) {
                            env.post({
                                phase: 'register-ok',
                                scanned: stats.scanned,
                                matched: stats.matched,
                                unregistered: stats.unregistered,
                                scope: SHARED_SCOPE
                            });
                            return registration;
                        }, function (err) {
                            var fail = errorSnapshot(err);
                            env.post({
                                phase: 'register-fail',
                                name: fail.name,
                                message: fail.message,
                                scanned: stats.scanned,
                                matched: stats.matched,
                                unregistered: stats.unregistered,
                                scope: SHARED_SCOPE
                            });
                            throw err;
                        });
                    } catch (err) {
                        var thrown = errorSnapshot(err);
                        env.post({
                            phase: 'register-fail',
                            name: thrown.name,
                            message: thrown.message,
                            scanned: stats.scanned,
                            matched: stats.matched,
                            unregistered: stats.unregistered,
                            scope: SHARED_SCOPE
                        });
                        return Promise.reject(err);
                    }
                });
        };
    }

    var api = {
        officialScript: OFFICIAL_SCRIPT,
        sharedScope: SHARED_SCOPE,
        shouldRewrite: shouldRewrite,
        isOfficialWorkerScript: isOfficialWorkerScript,
        isLegacyChannelScope: isLegacyChannelScope,
        copyOptions: copyOptions,
        migrateLegacyRegistrations: migrateLegacyRegistrations,
        createRegisterWrapper: createRegisterWrapper
    };

    if (typeof module !== 'undefined' && module.exports && typeof window === 'undefined') {
        module.exports = api;
        return;
    }

    if (window.__lwtvCctvSwCompat) return;
    window.__lwtvCctvSwCompat = true;
    if (window !== window.top) return;
    if (!navigator.serviceWorker || typeof navigator.serviceWorker.register !== 'function') return;

    var documentID = String(Date.now()) + '-sw-' + Math.random().toString(36).slice(2);
    var generation = 0;
    window.addEventListener('pagehide', function () {
        generation += 1;
    });

    function post(data) {
        try {
            if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.diag) {
                return;
            }
            window.webkit.messageHandlers.diag.postMessage({
                type: 'swCompat',
                data: data || {},
                href: String(location.origin + location.pathname),
                documentID: documentID,
                mainFrame: true,
                session: Number(window.__lwtvProbeSession || 0)
            });
        } catch (e) { }
    }

    var container = navigator.serviceWorker;
    var originalRegister = container.register;
    var wrapped = createRegisterWrapper(originalRegister, {
        href: function () { return String(location.href); },
        origin: function () { return String(location.origin); },
        generation: function () { return generation; },
        getRegistrations: function () {
            if (typeof container.getRegistrations !== 'function') {
                return Promise.resolve([]);
            }
            return container.getRegistrations();
        },
        post: post
    });

    try {
        container.register = wrapped;
    } catch (e) {
        var fail = errorSnapshot(e);
        post({ phase: 'wrap-fail', name: fail.name, message: fail.message });
    }
})(typeof window !== 'undefined' ? window : this);
