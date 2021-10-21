cargoRewriteConfigHook() {
    echo "LASJKDLKAJSD"
    cat .cargo/config

    set -x
    echo @mergeCargoLock@

#    cat >> .cargo/config <<EOF
#[source."library"]
#"directory" = "/nix/store/iz8h5l1q4r8dqg88rwqapyi1p4ygcfv4-rust-src/lib/rustlib/src/rust/library/"
#EOF
    cat .cargo/config
}

if [ -z "${dontCargoRewriteConfig-}" ]; then
  postUnpackHooks+=(cargoRewriteConfigHook)
fi
