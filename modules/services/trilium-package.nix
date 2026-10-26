{ pkgs }:
# Keep the rest of Nixpkgs pinned while trialling a release with built-in MCP.
# Adapt the pinned package's wrapper to the upstream ESM server distribution.
pkgs.trilium-server.overrideAttrs {
  version = "0.106.1";
  src = pkgs.fetchurl {
    url = "https://github.com/TriliumNext/Trilium/releases/download/v0.106.1/TriliumNotes-Server-v0.106.1-linux-x64.tar.xz";
    hash = "sha256-WbWR275Cizo4pJPYlUuwOE8RjFyT5F2b/YuJJwwo1iA=";
  };
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/trilium-server"
    cp -r ./* "$out/share/trilium-server/"
    # The glibc host uses the glibc prebuild; musl binaries cannot be patched.
    rm -f "$out/share/trilium-server/node_modules/better-sqlite3/prebuilds"/linuxmusl-*.node
    makeWrapper "$out/share/trilium-server/node/bin/node" "$out/bin/trilium-server" \
      --chdir "$out/share/trilium-server" \
      --add-flags "main.mjs"
    runHook postInstall
  '';
  meta = pkgs.trilium-server.meta // {
    platforms = [ "x86_64-linux" ];
  };
}
