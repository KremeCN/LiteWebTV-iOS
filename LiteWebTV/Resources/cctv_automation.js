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

    function hidePageChrome() {
        var selectors = [
            '.headernew',
            '#guanggao',
            '.ggcontainer',
            '.ind_livepageProgram_xq18570',
            '.title19600',
            '#hasAppNew',
            '.tj_iframe',
            '#framecomentnew',
            '#yspiframe',
            '.logoBiao',
            '.column_wrapper',
            '.zhibo19629_galaxy01',
            '.footer',
            '.swiper-container'
        ];
        selectors.forEach(function (sel) {
            document.querySelectorAll(sel).forEach(function (el) {
                el.style.setProperty('display', 'none', 'important');
            });
        });
        document.body.style.backgroundColor = 'black';
        document.documentElement.style.backgroundColor = 'black';
        document.body.style.overflow = 'hidden';
    }

    function applyFullscreenPlayer() {
        var ids = ['player', 'html5Player', 'html5Player_live', 'html5VideoBack', 'html5ControlDiv'];
        ids.forEach(function (id) {
            var el = document.getElementById(id);
            if (!el) return;
            el.style.cssText = 'position:fixed!important;top:0!important;left:0!important;width:100vw!important;height:100vh!important;z-index:99999!important;background:#000!important;margin:0!important;padding:0!important;overflow:hidden!important;';
        });

        var videoBox = document.querySelector('.video_box');
        if (videoBox) {
            videoBox.style.cssText = 'position:fixed!important;top:0!important;left:0!important;width:100vw!important;height:100vh!important;z-index:99998!important;background:#000!important;margin:0!important;padding:0!important;';
        }

        var video = document.querySelector('video');
        if (video) {
            video.style.cssText = 'width:100%!important;height:100%!important;object-fit:contain!important;';
            video.setAttribute('playsinline', 'true');
            video.setAttribute('webkit-playsinline', 'true');
        }
    }

    function tryPlayVideo() {
        var video = document.querySelector('video');
        if (!video) return false;

        if (video.muted) {
            video.muted = false;
        }
        if (video.paused) {
            video.play().catch(function () {});
        }
        return true;
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

    function tryDismissSplash() {
        var video = document.querySelector('video');
        if (!video) return;
        if (!video.paused && video.readyState >= 3 && video.currentTime > 0.1) {
            if (window.Android && window.Android.dismissSplash) {
                window.Android.dismissSplash();
            }
        }
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
            attributeFilter: ['style', 'class']
        });
    }

    addTask('pagePrep', function () {
        disableAllInputs();
        hidePageChrome();
        applyFullscreenPlayer();
        var hasPlayer = !!(document.getElementById('player') || document.querySelector('video'));
        return hasPlayer;
    });

    addTask('autoPlay', function () {
        applyFullscreenPlayer();
        if (tryPlayVideo()) return true;
        return clickPlayButton();
    });

    addTask('unmute', function () {
        var video = document.querySelector('video');
        if (!video) return false;
        if (video.muted) video.muted = false;
        return true;
    });

    addTask('quality', function () {
        applyFullscreenPlayer();
        return selectHighestQuality();
    });

    addTask('fullscreen', function () {
        applyFullscreenPlayer();
        return !!document.querySelector('video');
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

    // 持续维护全屏与隐藏（永久任务）
    addTask('maintainLayout', function () {
        hidePageChrome();
        applyFullscreenPlayer();
        return false;
    });

    window.extractData = function () { };

})();
