/**
 * Bridge Shim: Android → iOS WKWebView 兼容层
 *
 * 此脚本在 automation.js 之前注入。
 * 创建一个假的 window.Android 对象，将所有调用转发到
 * iOS 的 WKScriptMessageHandler (window.webkit.messageHandlers.bridge)。
 *
 * 这样 automation.js 可以一字不改地在 iOS 上运行。
 */
window.Android = {
    receiveChannelList: function(json) {
        window.webkit.messageHandlers.bridge.postMessage({type: 'channelList', data: json});
    },
    receiveProgramList: function(json) {
        window.webkit.messageHandlers.bridge.postMessage({type: 'programList', data: json});
    },
    receiveTitle: function(title) {
        window.webkit.messageHandlers.bridge.postMessage({type: 'title', data: title});
    },
    dismissSplash: function() {
        window.webkit.messageHandlers.bridge.postMessage({type: 'dismissSplash'});
    }
};
