(function () {
    'use strict';

    // 画质优先级：选菜单里实际存在的最高档（网页直播常见最高为「超清」）
    var QUALITY_TIERS = [
        { keys: ['4K'], rank: 100 },
        { keys: ['蓝光', '1080P', '1080'], rank: 90 },
        { keys: ['超清', '720'], rank: 80 },
        { keys: ['高清', '540'], rank: 70 },
        { keys: ['标清', '480'], rank: 60 },
        { keys: ['流畅', '360'], rank: 50 }
    ];

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

    // 只挡广告和跳 App，保留手机页本身。以前把 header/节目单藏掉再 100vh 铺播放器，看起来像电脑横屏站。
    function hideBlockingOverlays() {
        var selectors = [
            '#guanggao',
            '.ggcontainer',
            '#hasAppNew',
            '.tj_iframe',
            '#framecomentnew',
            '#yspiframe',
            '.logoBiao'
        ];
        selectors.forEach(function (sel) {
            document.querySelectorAll(sel).forEach(function (el) {
                if (el.getAttribute('data-lwtv-hidden') === '1') return;
                el.style.setProperty('display', 'none', 'important');
                el.setAttribute('data-lwtv-hidden', '1');
            });
        });
    }

    // Safari iPhone 页内 FairPlay 需要 playsinline；去掉后 liveplayer 会当成不能播 DRM。
    function prepareInlineVideo() {
        var video = document.querySelector('video');
        if (!video) return false;
        video.setAttribute('playsinline', 'true');
        video.setAttribute('webkit-playsinline', 'true');
        return true;
    }

    function tryPlayVideo() {
        var video = document.querySelector('video');
        if (!video) return false;
        if (!video.paused) return true;

        // iOS 允许静音自动播放；起播后再由 unmute 任务取消静音
        video.muted = true;
        var playPromise = video.play();
        if (playPromise && typeof playPromise.then === 'function') {
            playPromise.catch(function () { });
            return false;
        }
        return !video.paused;
    }

    function clickPlayButton() {
        var selectors = [
            '#playbtn_img',
            '.playbtn',
            '[id*="playbtn"]',
            '.y-full-control-btnl .play.play1'
        ];
        for (var i = 0; i < selectors.length; i++) {
            var btn = document.querySelector(selectors[i]);
            if (btn && window.getComputedStyle(btn).display !== 'none') {
                btn.click();
                return true;
            }
        }
        return false;
    }

    function rankForText(text) {
        var normalized = (text || '').trim();
        if (!normalized || normalized === '自动' || normalized.indexOf('下载') >= 0) {
            return -1;
        }
        var best = -1;
        QUALITY_TIERS.forEach(function (tier) {
            tier.keys.forEach(function (key) {
                if (normalized === key || normalized.indexOf(key) >= 0) {
                    if (tier.rank > best) best = tier.rank;
                }
            });
        });
        return best;
    }

    function openQualityMenu() {
        var triggers = document.querySelectorAll('div, span, li, a, button');
        for (var i = 0; i < triggers.length; i++) {
            var el = triggers[i];
            var text = (el.textContent || '').trim();
            if (text === '自动' || text === '清晰度' || text.indexOf('自动') === 0) {
                el.click();
                return true;
            }
        }
        return false;
    }

    function selectHighestQuality() {
        openQualityMenu();

        var bestEl = null;
        var bestRank = -1;
        var clickable = document.querySelectorAll('div, span, li, a, button');

        clickable.forEach(function (el) {
            if (!el || el.offsetParent === null) return;
            var text = (el.textContent || '').trim();
            if (!text || text.length > 12) return;

            var rank = rankForText(text);
            if (rank > bestRank) {
                var className = el.className || '';
                var isActive = className.indexOf('active') >= 0 || className.indexOf('cur') >= 0;
                if (!isActive || rank > bestRank) {
                    bestRank = rank;
                    bestEl = el;
                }
            }
        });

        if (bestEl && bestRank >= 0) {
            var activeClass = bestEl.className || '';
            if (activeClass.indexOf('active') < 0 && activeClass.indexOf('cur') < 0) {
                bestEl.click();
                postConsole('log', '[CCTV] Selected quality: ' + (bestEl.textContent || '').trim());
                return true;
            }
            return true;
        }
        return false;
    }

    // =========================================================
    // 任务注册式 MutationObserver（与 automation.js 同模式）
    // =========================================================
    var _tasks = new Map();
    var _observer = null;
    var _rafId = null;

    function addTask(id, fn) {
        _tasks.set(id, fn);
        if (!_observer) _startObserver();
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
            if (_tasks.size === 0 && _observer) {
                _observer.disconnect();
                _observer = null;
            }
        });
    }

    function _startObserver() {
        _observer = new MutationObserver(_scheduleRun);
        _observer.observe(document.documentElement, {
            childList: true,
            subtree: true,
            attributes: true,
            attributeFilter: ['class']
        });
    }

    addTask('pagePrep', function () {
        disableAllInputs();
        hideBlockingOverlays();
        prepareInlineVideo();
        return true;
    });

    addTask('autoPlay', function () {
        prepareInlineVideo();
        if (tryPlayVideo()) return true;
        return clickPlayButton();
    });

    addTask('unmute', function () {
        var video = document.querySelector('video');
        if (!video) return false;
        if (video.paused) return false;
        if (!video.muted) return true;
        video.muted = false;
        return true;
    });

    addTask('quality', function () {
        prepareInlineVideo();
        return selectHighestQuality();
    });

    addTask('nativePlayer', function () {
        return prepareInlineVideo();
    });

    addTask('videoDebug', function () {
        var video = document.querySelector('video');
        if (!video) return false;
        function describe() {
            var err = video.error;
            return 'src=' + (video.currentSrc || video.src || '')
                + ' ready=' + video.readyState
                + ' paused=' + video.paused
                + ' t=' + (video.currentTime || 0).toFixed(2)
                + (err ? (' error=' + err.code) : '');
        }
        postConsole('log', '[CCTV] video ' + describe());
        video.addEventListener('error', function () {
            postConsole('error', '[CCTV] video error ' + describe());
        });
        return true;
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
        video.addEventListener('loadstart', function () {
            dismissed = false;
        });

        check();
        return true;
    });

    addTask('layoutRefresh', function () {
        hideBlockingOverlays();
        prepareInlineVideo();
        return false;
    });

    addTask('rightsOverlay', function () {
        var bodyText = (document.body && document.body.innerText) || '';
        if (bodyText.indexOf('本时段节目请使用电脑端') < 0) {
            return false;
        }
        var video = document.querySelector('video');
        if (video && !video.paused && video.readyState >= 2) {
            return true;
        }
        postConsole('warn', '[CCTV] Rights overlay ua=' + navigator.userAgent);
        return false;
    });

    window.extractData = function () { };

})();
