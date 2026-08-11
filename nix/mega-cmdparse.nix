{
  vimUtils,
  fetchFromGitHub,
  mega-logging,
}:
vimUtils.buildVimPlugin {
  pname = "mega.cmdparse";
  version = "1.2.1";

  src = fetchFromGitHub {
    owner = "ColinKennedy";
    repo = "mega.cmdparse";
    rev = "v1.2.1";
    hash = "sha256-CwsAxuRnhrGqzmWfPEW0ZX4ohWZ7bNpCYbKYCpDLw60=";
  };

  dependencies = [ mega-logging ];
}
