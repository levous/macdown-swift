// Used instead of tasklist.js when "Enable checkbox toggling" is on: task
// list checkboxes that know their source line can be clicked, and report
// the change to the app, which edits the Markdown.
(function () {
  function update() {
    var items = document.getElementsByClassName('task-list-item');
    for (var i = 0; i < items.length; i++) {
      var input = items[i].getElementsByTagName('input')[0];
      if (input) input.disabled = !items[i].hasAttribute('data-source-line');
    }
  }

  if (!window.MacDownTaskList) {
    document.addEventListener('change', function (event) {
      var input = event.target;
      if (!input || input.type !== 'checkbox') return;
      var item = input.closest('li.task-list-item');
      if (!item || item.getElementsByTagName('input')[0] !== input) return;
      var line = parseInt(item.getAttribute('data-source-line'), 10);
      if (!line || !window.webkit) return;
      window.webkit.messageHandlers.MacDownTaskList.postMessage([line, input.checked]);
    });
  }
  window.MacDownTaskList = { update: update };
  update();
})();
