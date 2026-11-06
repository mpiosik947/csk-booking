"use client";

import { useLayoutEffect } from "react";

const guardKey = "__strzelajtuWizardHistory";

/** One same-URL guard entry lets Back be decided before the router discards the form. */
export default function useUnsavedNavigation(dirty: boolean, blocked: boolean) {
  useLayoutEffect(() => {
    const url = location.href;
    const active = dirty || blocked;
    const allow = () => !blocked && (!dirty || window.confirm("Masz niezapisane zmiany. Opuścić stronę i je odrzucić?"));
    const marker = () => history.state?.[guardKey];
    const mark = (position: "base" | "guard") => ({ ...history.state, [guardKey]: { url, position } });
    if (active && (marker()?.url !== url || marker()?.position !== "guard")) {
      history.replaceState(mark("base"), "", url);
      history.pushState(mark("guard"), "", url);
    }
    let leaving = false;
    const unload = (event: BeforeUnloadEvent) => {
      if (active && !leaving) { event.preventDefault(); event.returnValue = ""; }
    };
    const click = (event: MouseEvent) => {
      const link = (event.target as Element)?.closest?.("a[href]");
      if (!active || !link || event.defaultPrevented || event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey || link.getAttribute("target") === "_blank") return;
      if (!allow()) { event.preventDefault(); event.stopPropagation(); }
    };
    const traverse = (event: PopStateEvent) => {
      if (leaving) return;
      if (marker()?.url === url && marker()?.position === "base" && location.href === url) {
        event.stopImmediatePropagation();
        if (allow()) {
          leaving = true;
          history.back();
        } else {
          history.pushState(mark("guard"), "", url);
        }
      } else if (active && location.href !== url && !allow()) {
        event.stopImmediatePropagation();
        history.pushState(original, "", url);
      }
    };
    const original = history.state;
    window.addEventListener("beforeunload", unload);
    document.addEventListener("click", click, true);
    window.addEventListener("popstate", traverse, true);
    return () => {
      window.removeEventListener("beforeunload", unload);
      document.removeEventListener("click", click, true);
      window.removeEventListener("popstate", traverse, true);
    };
  }, [dirty, blocked]);
}
