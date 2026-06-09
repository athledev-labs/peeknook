// SPDX-License-Identifier: Apache-2.0

function initMobileMenu() {
  const toggle = document.querySelector<HTMLButtonElement>(".menu-toggle");
  const menu = document.getElementById("site-menu");
  if (!toggle || !menu) return;

  let open = false;

  const setOpen = (next: boolean) => {
    open = next;
    toggle.setAttribute("aria-expanded", String(open));
    toggle.setAttribute("aria-label", open ? "Close menu" : "Open menu");
    toggle.classList.toggle("is-open", open);
    menu.classList.toggle("is-open", open);
    menu.hidden = !open;
    document.body.classList.toggle("menu-open", open);
  };

  toggle.addEventListener("click", () => setOpen(!open));

  menu.querySelectorAll<HTMLAnchorElement>("a[href]").forEach((link) => {
    link.addEventListener("click", () => setOpen(false));
  });

  menu.querySelectorAll<HTMLElement>("[data-menu-dismiss]").forEach((el) => {
    el.addEventListener("click", () => setOpen(false));
  });

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && open) setOpen(false);
  });

  window.matchMedia("(min-width: 721px)").addEventListener("change", (event) => {
    if (event.matches) setOpen(false);
  });
}

initMobileMenu();
