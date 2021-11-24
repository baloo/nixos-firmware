{ stdenv, python3Packages, openssl, lib}:

python3Packages.buildPythonPackage {
  pname = "pecoff-checksum";
  version = "0.0.0";

  src = ./.;
  pythonPath = with python3Packages; [ signify ];
  doCheck = false;

  makeWrapperArgs = let
    ldVar = if stdenv.isDarwin then "DYLD_LIBRARY_PATH" else "LD_LIBRARY_PATH";
  in [
    "--prefix"
    ldVar
    ":"
    (lib.makeLibraryPath [ openssl ])
  ];
  meta.description = "A PE image checksum calculation util";
}
