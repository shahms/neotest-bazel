# Neotest Bazel

A [neotest](https://github.com/nvim-eotest/neotest) adapter for [Bazel](https://bazel.build/), which aims to be flexible enough for use in large Bazel monorepos.

![image](https://github.com/user-attachments/assets/e9d8fcec-4880-4ede-9280-d9402298a570)

## Table of Contents

- [FAQs](#faqs)
- [Current Known Issues](#current-known-issues)
- [Development](#development)
- [Acknowledgements](#acknowledgements)

## FAQs

> How does this differ from [sluongng/neotest-bazel](https://github.com/sluongng/neotest-bazel)?

My primary goal is to make this plugin usable in large monorepos, which may otherwise struggle with neotest's discovery while still being flexible enough to enable eager discovery in smaller projects.
In terms of current functionality, [sluongng/neotest-bazel](https://github.com/sluongng/neotest-bazel) will currently run tests from within the language test file (if that language is supported),
while this project will only run tests from the `BUILD` file which defines the corresponding target.

## Current Known Issues

* Tests cannot be run from the language test file, only the BUILD file which defines the target.
* Within `BUILD` files, test target location is limited to the row and column of the opening parenthesis (as reported by `bazel query`) rather than encompassing the entire location.

## Development

### Run tests


Running tests requires either

- [luarocks][luarocks]
- or [busted][busted] and [nlua][nlua]

to be installed[^1].

[^1]: The test suite assumes that `nlua` has been installed
      using luarocks into `~/.luarocks/bin/`.

You can then run:

```bash
luarocks test --local
# or
busted
```

Or if you want to run a single test file:

```bash
luarocks test spec/path_to_file.lua --local
# or
busted spec/path_to_file.lua
```

If you see an error like `module 'busted.runner' not found`:

```bash
eval $(luarocks path --no-bin)
```

[rockspec-format]: https://github.com/luarocks/luarocks/wiki/Rockspec-format
[luarocks]: https://luarocks.org
[luarocks-api-key]: https://luarocks.org/settings/api-keys
[gh-actions-secrets]: https://docs.github.com/en/actions/security-guides/encrypted-secrets#creating-encrypted-secrets-for-a-repository
[busted]: https://lunarmodules.github.io/busted/
[nlua]: https://github.com/mfussenegger/nlua
[use-this-template]: https://github.com/new?template_name=nvim-lua-plugin-template&template_owner=nvim-lua

## Acknowledgements

- Insipriation taken from: [sluongng/neotest-bazel](https://github.com/sluongng/neotest-bazel).
