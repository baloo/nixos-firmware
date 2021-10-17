{ ...
}:

{ ...
}: {
 config = {
   boot.initrd.kernelModules = [
      "dm_verity"
   ];
 };
}


