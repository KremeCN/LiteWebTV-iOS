(function () {
    'use strict';

    function postConsole(level, msg) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
            window.webkit.messageHandlers.bridge.postMessage({ type: 'console', level: level, data: msg });
        }
    }

    function disableAllInputs() {
        document.querySelectorAll('input, textarea, [contenteditable="true"]').forEach(function (el) {
            el.setAttribute('disabled', 'true');
            el.setAttribute('readonly', 'true');
            el.blur();
        });
    }

    function hideBlockingOverlays() {
        ['#guanggao', '.ggcontainer', '#hasAppNew', '.tj_iframe', '#framecomentnew', '#yspiframe', '.logoBiao'].forEach(function (sel) {
            document.querySelectorAll(sel).forEach(function (el) {
                if (el.getAttribute('data-lwtv-hidden') === '1') return;
                el.style.setProperty('display', 'none', 'important');
                el.setAttribute('data-lwtv-hidden', '1');
            });
        });
        if (document.body && document.body.getAttribute('data-lwtv-page') !== '1') {
            document.body.style.overflow = 'hidden';
            document.documentElement.style.overflow = 'hidden';
            document.body.setAttribute('data-lwtv-page', '1');
        }
    }

    function tryPlayVideo() {
        var video = document.querySelector('video');
        if (!video) return false;
        if (!video.paused) return true;
        var playPromise = video.play();
        if (playPromise && typeof playPromise.then === 'function') {
            playPromise.catch(function (err) {
                postConsole('warn', '[CCTV] play rejected ' + (err && err.name) + ' ' + (err && err.message));
            });
            return false;
        }
        return !video.paused;
    }

    function clickPlayButton() {
        var selectors = ['#playbtn_img', '.playbtn', '[id*="playbtn"]'];
        for (var i = 0; i < selectors.length; i++) {
            var btn = document.querySelector(selectors[i]);
            if (btn && window.getComputedStyle(btn).display !== 'none') {
                btn.click();
                return true;
            }
        }
        return false;
    }

    var _tasks = new Map();
    var _observer = null;
    var _rafId = null;

    function addTask(id, fn) {
        _tasks.set(id, fn);
        if (!_observer) {
            _observer = new MutationObserver(_scheduleRun);
            _observer.observe(document.documentElement, {
                childList: true,
                subtree: true,
                attributes: true,
                attributeFilter: ['class']
            });
        }
        _scheduleRun();
    }

    function _scheduleRun() {
        if (_rafId !== null) return;
        _rafId = requestAnimationFrame(function () {
            _rafId = null;
            _tasks.forEach(function (fn, id) {
                try {
                    if (fn()) _tasks.delete(id);
                } catch (e) { }
            });
        });
    }

    addTask('pagePrep', function () {
        disableAllInputs();
        hideBlockingOverlays();
        return true;
    });

    addTask('autoPlay', function () {
        if (tryPlayVideo()) return true;
        return clickPlayButton();
    });

    addTask('videoMonitor', function () {
        var video = document.querySelector('video');
        if (!video) return false;
        var dismissed = false;
        function check() {
            if (dismissed) return;
            if (!video.paused && video.readyState >= 3 && video.currentTime > 0.1) {
                if (window.Android && window.Android.dismissSplash) {
                    window.Android.dismissSplash();
                    dismissed = true;
                }
            }
        }
        video.addEventListener('playing', check);
        video.addEventListener('timeupdate', check);
        check();
        return true;
    });

    addTask('layoutRefresh', function () {
        hideBlockingOverlays();
        return false;
    });

    window.extractData = function () { };
})();
