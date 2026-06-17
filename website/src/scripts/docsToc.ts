// SPDX-License-Identifier: Apache-2.0

/** Highlight the "On this page" link for the section currently in view. */
function initToc() {
  const links = Array.from(
    document.querySelectorAll<HTMLAnchorElement>(".docs-toc-link"),
  );
  if (!links.length) return;

  const byId = new Map<string, HTMLAnchorElement>();
  for (const link of links) {
    const id = link.dataset.toc;
    if (id) byId.set(id, link);
  }

  const targets = Array.from(byId.keys())
    .map((id) => document.getElementById(id))
    .filter((el): el is HTMLElement => Boolean(el));
  if (!targets.length) return;

  const setActive = (id: string) => {
    for (const link of links) {
      link.classList.toggle("is-active", link.dataset.toc === id);
    }
  };

  let activeId = targets[0].id;
  setActive(activeId);

  const observer = new IntersectionObserver(
    (entries) => {
      const visible = entries
        .filter((e) => e.isIntersecting)
        .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
      if (visible[0]) {
        activeId = visible[0].target.id;
        setActive(activeId);
      }
    },
    { rootMargin: "-88px 0px -68% 0px", threshold: 0 },
  );

  for (const target of targets) observer.observe(target);
}

/** Add a copy button to each code block. */
function initCodeCopy() {
  const blocks = document.querySelectorAll<HTMLPreElement>(".docs-content pre");
  blocks.forEach((pre) => {
    if (pre.querySelector(".code-copy")) return;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "code-copy";
    button.setAttribute("aria-label", "Copy code");
    button.textContent = "Copy";
    button.addEventListener("click", async () => {
      const code = pre.querySelector("code")?.innerText ?? pre.innerText;
      try {
        await navigator.clipboard.writeText(code.replace(/\n$/, ""));
        button.textContent = "Copied";
        button.classList.add("is-copied");
        window.setTimeout(() => {
          button.textContent = "Copy";
          button.classList.remove("is-copied");
        }, 1600);
      } catch {
        /* clipboard unavailable */
      }
    });
    pre.appendChild(button);
  });
}

initToc();
initCodeCopy();
