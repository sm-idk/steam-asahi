{
  upstream,
}:

upstream.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./portal/remotes.patch ];
  postPatch = (old.postPatch or "") + ''
    cp ${./portal/pipewire.rs} crates/muvm/src/guest/bin/muvm-portal-pipewire.rs
    cp ${../../lib/transport/unix/stream.rs} crates/muvm/src/guest/bridge/unix_stream.rs
  '';
})
