(function () {

MathJax.Hub.Config({
	'showProcessingMessages': false,
	'messageStyle': 'none'
});

if (window.webkit && window.webkit.messageHandlers
		&& window.webkit.messageHandlers.MathJaxListener) {
	MathJax.Hub.Register.StartupHook('End', function () {
		window.webkit.messageHandlers.MathJaxListener.postMessage('End');
	});
}

})();
