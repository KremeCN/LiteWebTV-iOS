(function () {
    'use strict';

    window.__lwtvH5eConfigLoaded = false;
    window.__lwtvH5eLastFetch = '';

    function markConfig() {
        window.__lwtvH5eConfigLoaded = true;
    }

    function isConfigURL(url) {
        var text = String(url || '').toLowerCase();
        return text.indexOf('h5player') >= 0 || text.indexOf('/library/') >= 0;
    }

    function rewrite(url) {
        try {
            var parsed = new URL(String(url), location.href);
            var path = parsed.pathname;
            if (path.indexOf('/Library/') === 0 || path.indexOf('/library/') === 0) {
                return location.origin + path + parsed.search;
            }
        } catch (err) {}
        return url;
    }

    function emptyFilesDB() {
        function request(result) {
            var req = { result: result, error: null, onsuccess: null, onerror: null };
            setTimeout(function () {
                if (typeof req.onsuccess === 'function') {
                    req.onsuccess({ target: req });
                }
            }, 0);
            return req;
        }
        return {
            objectStoreNames: { contains: function (name) { return name === 'FILES'; } },
            createObjectStore: function () { return {}; },
            deleteObjectStore: function () {},
            transaction: function () {
                return {
                    objectStore: function () {
                        return {
                            get: function () { return request(undefined); },
                            put: function () { return request(undefined); }
                        };
                    }
                };
            }
        };
    }

    if (window.indexedDB && indexedDB.open) {
        var origOpen = indexedDB.open.bind(indexedDB);
        indexedDB.open = function (name, version) {
            var real;
            try {
                real = origOpen(name, version);
            } catch (err) {
                real = null;
            }
            var wrapped = { onsuccess: null, onerror: null, onupgradeneeded: null };
            if (!real) {
                setTimeout(function () {
                    wrapped.result = emptyFilesDB();
                    if (typeof wrapped.onsuccess === 'function') {
                        wrapped.onsuccess({ target: wrapped });
                    }
                }, 0);
                return wrapped;
            }
            real.addEventListener('success', function (event) {
                wrapped.result = event.target.result;
                if (typeof wrapped.onsuccess === 'function') {
                    wrapped.onsuccess({ target: wrapped });
                }
            });
            real.addEventListener('error', function () {
                wrapped.result = emptyFilesDB();
                if (typeof wrapped.onsuccess === 'function') {
                    wrapped.onsuccess({ target: wrapped });
                }
            });
            real.addEventListener('upgradeneeded', function (event) {
                wrapped.result = event.target.result;
                if (typeof wrapped.onupgradeneeded === 'function') {
                    wrapped.onupgradeneeded({ target: wrapped });
                }
            });
            return wrapped;
        };
    }

    if (window.IDBObjectStore && IDBObjectStore.prototype.get) {
        var origGet = IDBObjectStore.prototype.get;
        IDBObjectStore.prototype.get = function (key) {
            var req = origGet.call(this, key);
            if (isConfigURL(key)) {
                req.addEventListener('success', function () {
                    if (req.result) markConfig();
                });
            }
            return req;
        };
    }

    var origFetch = window.fetch.bind(window);
    window.fetch = function (input, init) {
        var url = typeof input === 'string' ? rewrite(input) : (input && input.url ? rewrite(input.url) : input);
        var req = (typeof input === 'string') ? url : (input && input.url ? new Request(url, input) : input);
        if (isConfigURL(url)) window.__lwtvH5eLastFetch = String(url);
        var pending = origFetch(req, init);
        if (isConfigURL(url)) pending.then(markConfig, markConfig);
        return pending;
    };

    var origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
        var next = typeof url === 'string' ? rewrite(url) : url;
        arguments[1] = next;
        window.__lwtvH5eLastFetch = String(next);
        if (isConfigURL(next)) {
            this.addEventListener('loadend', function () {
                if (this.status === 0 || (this.status >= 200 && this.status < 300)) markConfig();
            });
        }
        return origOpen.apply(this, arguments);
    };
})();
