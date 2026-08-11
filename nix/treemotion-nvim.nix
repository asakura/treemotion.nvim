{
  vimUtils,
  neovim,
  lua51Packages,
  self,
  mega-cmdparse,
  mega-logging,
}:
vimUtils.buildVimPlugin {
  pname = "treemotion.nvim";
  version = self.shortRev or self.dirtyShortRev or "dev";

  src = self;

  dependencies = [
    mega-cmdparse
    mega-logging
  ];

  doCheck = true;
  nativeCheckInputs = [
    neovim
    lua51Packages.busted
  ];

  # Mirrors `bustedConfig` in `flake.nix` (same `lpath`/`lua` shape), but
  # this copy has to be self-contained: it runs inside the package's own
  # build sandbox, against this derivation's `dependencies`, not against a
  # live checkout's dev shell.
  checkPhase = ''
    runHook preCheck

    cat > .busted <<'EOF'
    return {
      _all = {
        coverage = false,
        lpath = "lua/?.lua;lua/?/init.lua;spec/?.lua;${mega-cmdparse}/lua/?.lua;${mega-cmdparse}/lua/?/init.lua;${mega-logging}/lua/?.lua;${mega-logging}/lua/?/init.lua",
        lua = "nvim -u NONE -U NONE -N -i NONE -l",
      },
      default = {
        helper = "./spec/minimal_init.lua",
        verbose = true,
      },
    }
    EOF

    busted .

    # These are checkPhase-only byproducts; installPhase copies the whole
    # working tree into $out, so leaving them behind would ship build
    # artifacts in the package.
    rm -f .busted nvim.log

    runHook postCheck
  '';
}
