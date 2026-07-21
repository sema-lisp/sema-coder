# Overlay modal prototypes

Throwaway design prototypes for the reusable **scrollable, selectable-list
modal** — the overlay used by involved flows (MCP CRUD, resume, and later
forge/workflows). This is **not** the completion palette; that stays as-is for
quick inline picks. This is the heavier surface with its own view + actions.

```
sema prototypes/overlay/gallery.sema      # best in a real terminal (true color)
```

`gallery.sema` renders four candidate looks for the same MCP-CRUD list, plus a
nested detail view, an empty state, and the same chrome re-used for a sessions
list (to show the modal is data-driven, not MCP-specific). Nothing here is wired
into the app.

Pick a direction and we:
1. finalize `docs/overlay-registry-design.md` around it,
2. port `:mcp` / `:resume` onto a `render-item`-driven modal,
3. add the overlay **registry** + an overlay **stack** (both decided), keeping
   the **mutate-in-place** state model.

The styles differ only in *chrome* (borders, selection marker, density); the
item model and the scroll/selection/action-footer behavior are shared, so a
choice here is purely aesthetic and can be mixed per view (e.g. a list view in
one style, a detail view in another).
