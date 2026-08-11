{
  vimUtils,
  fetchFromGitHub,
}:
vimUtils.buildVimPlugin {
  pname = "mega.logging";
  version = "1.1.6";

  src = fetchFromGitHub {
    owner = "ColinKennedy";
    repo = "mega.logging";
    rev = "v1.1.6";
    hash = "sha256-hV7uJyu0XszGLOvcRcDNDE9P6d8GTxBX+la1lQVxx2s=";
  };
}
