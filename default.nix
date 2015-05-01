{ mkDerivation, aeson, aeson-pretty, base, bytestring, directory
, errors, filepath, http-streams, io-streams, process, stdenv, text
, transformers, unordered-containers
}:
mkDerivation {
  pname = "melpa2nix";
  version = "0.1.0.0";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  buildDepends = [
    aeson aeson-pretty base bytestring directory errors filepath
    http-streams io-streams process text transformers
    unordered-containers
  ];
  description = "Automatically generate Nix expressions for Emacs packages";
  license = stdenv.lib.licenses.gpl3;
}
