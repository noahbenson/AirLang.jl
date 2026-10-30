# Building the Air book

These pages are a [Jupyter Book 2](https://jupyterbook.org/) site, rendered by
the [MyST](https://mystmd.org/) engine. The configuration is `myst.yml`; its
table of contents lists the pages.

```bash
bin/build-docs             # static site in book/_build/html
bin/build-docs --serve     # live preview at http://localhost:3000
bin/build-docs --strict    # fail on warnings (as CI does)
bin/deploy-docs            # build and publish to GitHub Pages
```

`myst` is a Node tool, so Node 18+ is required; the scripts use `npx`, so no
global install is needed. The examples are shown as code with their results in
comments and are **not** executed during the build, so neither Julia nor a
database is needed to render the site.

A GitHub **project** page is served from `https://<user>.github.io/AirLang.jl/`,
so the published build must set `BASE_URL=/AirLang.jl` (as `bin/deploy-docs` and
the workflow do). A local build without it is served from the site root, which
is what `--serve` expects.

The GitHub workflow in `.github/workflows/docs.yml` builds the book on every
pull request and publishes it to the `gh-pages` branch on `main` and on tags.
To enable the published site, set the repository's Pages source to the
`gh-pages` branch.
