// Renders ```mermaid code blocks as diagrams (Mermaid 12).
//
// Each block is hoedown's <div><pre><code class="language-mermaid">; the
// <div> is replaced with the diagram. The preview calls
// MacDownMermaid.render() again after it replaces the page body in place.

(function () {
  if (!window.mermaid) return;

  mermaid.initialize({
    startOnLoad: false,
    theme: "forest",
    securityLevel: "strict",
    // Report errors next to the block instead of adding an error diagram
    // to the end of the page.
    suppressErrorRendering: true,
    // Keep Mermaid's default HTML labels: with SVG text labels
    // (htmlLabels: false), Mermaid 12 draws mindmap labels off-center.
    flowchart: { useMaxWidth: true }
  });

  var count = 0;

  async function render() {
    var blocks = document.querySelectorAll("code.language-mermaid");
    for (var i = 0; i < blocks.length; i++) {
      var code = blocks[i];
      var container = code.parentElement;
      if (container.tagName === "PRE" && container.parentElement !== document.body) {
        container = container.parentElement;
      }
      var id = "macdown-mermaid-" + count++;
      try {
        var result = await mermaid.render(id, code.textContent);
        container.innerHTML = result.svg;
        container.classList.add("mermaid-diagram");
        if (result.bindFunctions) result.bindFunctions(container);
      } catch (error) {
        // Mermaid can leave its scratch element behind when it fails.
        var scratch = document.getElementById("d" + id);
        if (scratch) scratch.remove();
        var message = document.createElement("div");
        message.className = "mermaid-error";
        message.textContent = "Mermaid: " + ((error && error.message) || error);
        container.appendChild(message);
        code.classList.remove("language-mermaid");
      }
    }
  }

  window.MacDownMermaid = { render: render };
  window.addEventListener("load", function () { render(); });
})();
