{
  description = "treemotion.nvim: Treesitter-driven w/e/b/ge/W/E/B/gE motions, per filetype";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      overlay =
        _final: prev:
        let
          callPackage = prev.lib.callPackageWith (prev // packages);

          packages = {
            mega-logging = callPackage ./nix/mega-logging.nix { };
            mega-cmdparse = callPackage ./nix/mega-cmdparse.nix { };
            treemotion-nvim = callPackage ./nix/treemotion-nvim.nix { inherit self; };
          };
        in
        {
          vimPlugins = prev.vimPlugins // packages;
        };
    in
    {
      overlays.default = overlay;
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        };

        # Purely optional test-time plumbing: `treemotion-nvim` itself doesn't
        # depend on this and builds fine without it.
        treesitterAllGrammars = pkgs.symlinkJoin {
          name = "treemotion-treesitter-all-grammars";
          paths = builtins.attrValues (
            removeAttrs pkgs.vimPlugins.nvim-treesitter-parsers [
              "override"
              "overrideDerivation"
              "recurseForDerivations"
            ]
          );
        };

        lua51 = pkgs.lua51Packages;

        toLuaAnnotationModule =
          {
            pname,
            src,
            version ? "unstable",
            propagatedBuildInputs ? [ ],
          }:
          lua51.toLuaModule (
            pkgs.stdenvNoCC.mkDerivation {
              inherit
                pname
                src
                version
                propagatedBuildInputs
                ;
              dontBuild = true;

              installPhase = ''
                mkdir -p $out
                cp -r . $out/
              '';
            }
          );

        luaTypesBustedModule = toLuaAnnotationModule {
          pname = "lua-types-busted";
          src = pkgs.fetchFromGitHub {
            owner = "LuaCATS";
            repo = "busted";
            rev = "5ed85d0e016a5eb5eca097aa52905eedf1b180f1";
            hash = "sha256-A8YgMXtKnd9nSsRClkfz8cUbKHIUTRN2vudge6EfSgU=";
          };
        };

        luaTypesLuassertModule = toLuaAnnotationModule {
          pname = "lua-types-luassert";
          src = pkgs.fetchFromGitHub {
            owner = "LuaCATS";
            repo = "luassert";
            rev = "d3528bb679302cbfdedefabb37064515ab95f7b9";
            hash = "sha256-p8ohFmag2WKzDG7avgmw7qr9yA5Q/F2vhXakr3WHZUk=";
          };
        };

        lustache = lua51.buildLuarocksPackage {
          pname = "lustache";
          version = "1.3.1-0";

          knownRockspec =
            (pkgs.fetchurl {
              url = "https://luarocks.org/lustache-1.3.1-0.rockspec";
              hash = "sha256-TqFuhQ07KxEpwYhHrWG/tp6JPNTR2PSo59hRTkDgrbE=";
            }).outPath;

          src = pkgs.fetchFromGitHub {
            owner = "Olivine-Labs";
            repo = "lustache";
            rev = "v1.3.1-0";
            hash = "sha256-c+HhWv/ApXFaZj+RI5S3PkrG7bhzp/11aUXILQqiCW0=";
          };
        };

        luacovMultiple = lua51.buildLuarocksPackage {
          pname = "luacov-multiple";
          version = "0.6-1";

          knownRockspec =
            (pkgs.fetchurl {
              url = "https://luarocks.org/luacov-multiple-0.6-1.rockspec";
              hash = "sha256-0gWLWXotAHMBV17E5Sq1SntVmR2GZzOgO8qR9VBIoXI=";
            }).outPath;

          src = pkgs.fetchFromGitHub {
            owner = "to-kr";
            repo = "luacov-multiple";
            rev = "v0.6";
            hash = "sha256-T2YsPEWiamXwPnV4w2NecVXZgqqoWo4X+XWRTX9rP0M=";
          };

          propagatedBuildInputs = [
            lua51.luacov
            lua51.luafilesystem
            lustache
          ];
        };

        luaCoverageEnv = pkgs.lua5_1.withPackages (ps: [
          ps.busted
          ps.luacov
          ps.luafilesystem
          lustache
          luacovMultiple
        ]);

        devTools = with pkgs; [
          neovim
          git
          lua51.luarocks
          lua51.busted
          lua51.luacheck
          lua51.luacov
          lua51.llscheck
          lua-language-server
          stylua
          mdformat
          nixfmt
          miniserve
          statix
          panvimdoc
        ];

        neovimRuntime = "${pkgs.neovim-unwrapped}/share/nvim/runtime";

        luarcJson =
          pkgs.writeText "luarc.json"
            # json
            ''
              {
                  "diagnostics.libraryFiles": "Disable",
                  "runtime.version": "LuaJIT",
                  "workspace.checkThirdParty": "Disable",
                  "workspace.ignoreDir": [],
                  "workspace.library": [
                      "${luaTypesBustedModule}/library",
                      "${luaTypesLuassertModule}/library",
                      "${pkgs.vimPlugins.luvit-meta}/library",
                      "${pkgs.vimPlugins.mega-cmdparse}/lua",
                      "${pkgs.vimPlugins.mega-logging}/lua",
                      "${neovimRuntime}/lua"
                  ]
              }
            '';

        bustedConfig =
          pkgs.writeText ".busted"
            # lua
            ''
              return {
                _all = {
                  coverage = false,
                  lpath = "lua/?.lua;lua/?/init.lua;spec/?.lua;${pkgs.vimPlugins.mega-cmdparse}/lua/?.lua;${pkgs.vimPlugins.mega-cmdparse}/lua/?/init.lua;${pkgs.vimPlugins.mega-logging}/lua/?.lua;${pkgs.vimPlugins.mega-logging}/lua/?/init.lua",
                  lua = "nvim -u NONE -U NONE -N -i NONE --cmd 'set rtp+=${treesitterAllGrammars}' -l",
                },
                default = {
                  helper = "./spec/minimal_init.lua",
                  verbose = true,
                },
                tests = {
                  verbose = true,
                },
              }
            '';

        dependencyLinks = pkgs.linkFarm "treemotion-dependency-links" {
          ".luarc.json" = luarcJson;
          ".busted" = bustedConfig;
        };

        linkDependencies = "${pkgs.lndir}/bin/lndir -silent ${dependencyLinks} .";

        # A `checks`-compatible derivation that runs `script` inside a
        # writable copy of this flake's source tree.
        mkCheck =
          name: script:
          pkgs.runCommand "check-${name}" { nativeBuildInputs = devTools; } ''
            export HOME="$TMPDIR"
            cp -r ${self} source
            chmod -R u+w source
            cd source
            ${linkDependencies}
            ${script}
            touch $out
          '';

        # A `nix run .#<name>`-compatible app that runs `script` against the
        # real checkout (not a sandboxed copy), so writes such as `stylua`'s
        # auto-format land where the user expects them.
        mkApp =
          name: description: script:
          let
            app = pkgs.writeShellApplication {
              inherit name;
              runtimeInputs = devTools;

              text = ''
                ${linkDependencies}
                ${script}
              '';
            };
          in
          {
            type = "app";
            program = "${app}/bin/${name}";
            meta.description = description;
          };

        # `nix fmt`'s target: a single derivation whose default binary
        # formats the whole tree, so `stylua`/`nixfmt` (each only aware of
        # their own language) are dispatched here rather than exposed
        # individually as `formatter`.
        formatterApp = pkgs.writeShellApplication {
          name = "treemotion-formatter";

          runtimeInputs = [
            pkgs.stylua
            pkgs.nixfmt
          ];

          text = ''
            stylua lua plugin scripts spec
            nixfmt flake.nix
          '';
        };

        llscheckScript =
          configpath: # bash
          ''
            export VIMRUNTIME="${neovimRuntime}"
            llscheck --configpath ${configpath} .
          '';

        runCoverage = # bash
          ''
            ${luaCoverageEnv}/bin/busted --coverage .
          '';

        minCoveragePercent = 35.00;

        checkCoverageThreshold = # bash
          ''
            luacov

            total_line="$(grep '^Total' luacov.report.out | tail -n1)"
            coverage="$(echo "$total_line" | awk '{print $NF}' | tr -d '%')"

            echo "Total coverage: $coverage% (minimum required: ${toString minCoveragePercent}%)"

            if ! awk -v cov="$coverage" -v min="${toString minCoveragePercent}" 'BEGIN { exit !(cov >= min) }'; then
              echo "Coverage $coverage% is below the required minimum of ${toString minCoveragePercent}%."
              exit 1
            fi
          '';
      in
      {
        devShells.default = pkgs.mkShell {
          packages = devTools;
          shellHook = linkDependencies;
        };

        checks = {
          luacheck =
            mkCheck "luacheck" # bash
              "luacheck lua plugin scripts spec";

          stylua =
            mkCheck "stylua" # bash
              "stylua lua plugin scripts spec --color always --check";

          nixfmt =
            mkCheck "nixfmt"
              # bash
              "nixfmt --check flake.nix";

          mdformat =
            mkCheck "mdformat" # bash
              "mdformat --check README.md markdown/manual/docs/index.md";

          test =
            mkCheck "test" # bash
              "busted .";

          llscheck = mkCheck "llscheck" (llscheckScript ".luarc.json");
          coverage = mkCheck "coverage" (runCoverage + checkCoverageThreshold);
          treemotion-nvim = pkgs.vimPlugins.treemotion-nvim;
        };

        packages = {
          default = pkgs.vimPlugins.treemotion-nvim;
          treemotion-nvim = pkgs.vimPlugins.treemotion-nvim;
        };

        apps = {
          stylua =
            mkApp "stylua" "Auto-format lua/plugin/scripts/spec in place with stylua"
              # bash
              "stylua lua plugin scripts spec";

          nixfmt =
            mkApp "nixfmt" "Auto-format flake.nix with nixfmt" # bash
              "nixfmt flake.nix";

          mdformat =
            mkApp "mdformat" "Auto-format README.md and markdown/manual/docs/index.md with mdformat"
              # bash
              "mdformat README.md markdown/manual/docs/index.md";

          luacheck =
            mkApp "luacheck" "Lint lua/plugin/scripts/spec with luacheck"
              # bash
              "luacheck lua plugin scripts spec";

          llscheck =
            mkApp "llscheck" "Type-check against a .luarc.json (default: ./.luarc.json) with llscheck"
              (llscheckScript ''"''${1:-.luarc.json}"'');

          test =
            mkApp "test" "Run the busted test suite" # bash
              "busted .";

          api-documentation =
            mkApp "api-documentation"
              "Regenerate doc/treemotion_api.txt + doc/treemotion_types.txt from LuaCATS docstrings"
              # bash
              ''
                nvim -u scripts/make_api_documentation/minimal_init.lua -l scripts/make_api_documentation/main.lua
              '';

          user-documentation =
            mkApp "user-documentation"
              "Regenerate doc/treemotion.txt from README.md with panvimdoc, then rebuild doc/tags"
              # bash
              ''
                # `panvimdoc.sh` hard-codes its `scripts/` dir to `/scripts` whenever
                # `GITHUB_ACTIONS=true` is set -- that check comes before `--scripts-dir`
                # is even considered, so unsetting the variable for this one command is
                # the only way to skip it.
                env -u GITHUB_ACTIONS panvimdoc \
                  --project-name treemotion \
                  --input-file README.md \
                  --vim-version "Neovim >= 0.8.0" \
                  --demojify true \
                  --treesitter true
                nvim --headless -c 'helptags doc' -c 'quit'
              '';

          coverage-html =
            mkApp "coverage-html" "Run busted under luacov and write an HTML coverage report to luacov_html/"
              (
                runCoverage
                +
                  # bash
                  ''
                    ${luaCoverageEnv}/bin/luacov --reporter multiple.html
                    luacov
                  ''
              );

          coverage-threshold =
            mkApp "coverage-threshold" "Check that luacov's total coverage meets the required minimum"
              checkCoverageThreshold;

          coverage-serve =
            mkApp "coverage-serve" "Serve luacov_html/ over HTTP with miniserve"
              # bash
              "miniserve luacov_html --index index.html --port 8000 --interfaces 127.0.0.1";
        };

        formatter = formatterApp;
      }
    );
}
