# Changelog

## 1.0.0 (2026-10-02)


### Features

* **health:** warn about unknown configuration keys ([#17](https://github.com/asakura/treemotion.nvim/issues/17)) ([3162999](https://github.com/asakura/treemotion.nvim/commit/3162999bb9754dcd01373f76eee7fcb6095a0db5))
* honor g:loaded_treemotion; pass configuration into splitter ([#26](https://github.com/asakura/treemotion.nvim/issues/26)) ([0889604](https://github.com/asakura/treemotion.nvim/commit/0889604f6ca6f507290878c90acd16bb613c6b53)), closes [#21](https://github.com/asakura/treemotion.nvim/issues/21)
* **motion:** opt-in Vim-like operator ranges for dw/cw/de ([#29](https://github.com/asakura/treemotion.nvim/issues/29)) ([e14c7c1](https://github.com/asakura/treemotion.nvim/commit/e14c7c145a4443e96ee6f251ac2927b9b98ca068))


### Bug Fixes

* **health:** merge a partial configuration over the defaults ([3162999](https://github.com/asakura/treemotion.nvim/commit/3162999bb9754dcd01373f76eee7fcb6095a0db5))
* **health:** report a non-table configuration section instead of crashing ([f28b12a](https://github.com/asakura/treemotion.nvim/commit/f28b12a71ed7fae14e44a29ae919b2a847905686))
* **motion:** ignore brackets in strings and comments for balancing ([#37](https://github.com/asakura/treemotion.nvim/issues/37)) ([7832495](https://github.com/asakura/treemotion.nvim/commit/7832495b8f333fb4d6cf05963ab345c0f191fa70)), closes [#31](https://github.com/asakura/treemotion.nvim/issues/31)
* **motion:** keep '&lt; and '&gt; when operators need an inclusive range ([#38](https://github.com/asakura/treemotion.nvim/issues/38)) ([6a5d081](https://github.com/asakura/treemotion.nvim/commit/6a5d081d1306d6a45126218c817b9e92405d64d1)), closes [#32](https://github.com/asakura/treemotion.nvim/issues/32)
* **motion:** keep unopened brackets and prose punctuation on dw ([#30](https://github.com/asakura/treemotion.nvim/issues/30)) ([ac33137](https://github.com/asakura/treemotion.nvim/commit/ac331377ccdf465415ef29823e49c21c48293f83))
* **motion:** land e/E on multi-byte characters and fix b/ge/B/gE blank-gap direction ([b46703f](https://github.com/asakura/treemotion.nvim/commit/b46703f3e0d60cc38f70c5b612ad9a3e42430ee0))
* **motion:** split multi-row prose word-by-word instead of one jump ([888f26f](https://github.com/asakura/treemotion.nvim/commit/888f26f47c9d653a19d5c3167c05e5ff72fe412c))
* **renovate:** add currentValueTemplate to commit-pinned regex manager ([4c48683](https://github.com/asakura/treemotion.nvim/commit/4c486832ccfc25f9e0c392682308cf9a52bf1c25))
* **renovate:** force semantic commit messages ([aae6c13](https://github.com/asakura/treemotion.nvim/commit/aae6c13f4f7a3f4b9963683a21f0a10225d5710f))

## Changelog
