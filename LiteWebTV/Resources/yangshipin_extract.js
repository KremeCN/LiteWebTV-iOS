(function () {
    'use strict';

    function sendChannels() {
        var channelItems = document.querySelectorAll('.tv-main-con-r-list-left .oveerflow-1');
        if (!channelItems.length) return false;
        var channelList = [];
        channelItems.forEach(function (item, index) {
            var span = item.querySelector('span');
            if (!span) return;
            var tag = span.querySelector('.tv-main-con-r-list-left-tag');
            if (tag) {
                var tagText = tag.textContent || '';
                if (tagText.indexOf('VIP') !== -1 || tagText.indexOf('限免') !== -1) return;
            }
            var fullText = span.textContent || '';
            if (tag) fullText = fullText.replace(tag.textContent, '');
            var name = fullText.trim();
            if (!name) return;
            channelList.push({
                index: index,
                name: name,
                isActive: item.classList.contains('tvSelect')
            });
        });
        if (!channelList.length || !window.Android || !window.Android.receiveChannelList) return false;
        window.Android.receiveChannelList(JSON.stringify(channelList));
        return true;
    }

    var tries = 0;
    var timer = setInterval(function () {
        tries += 1;
        if (sendChannels() || tries > 40) clearInterval(timer);
    }, 250);
})();
