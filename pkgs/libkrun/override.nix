{
  upstream,
}:

upstream.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./portal/remotes.patch ];
  postPatch = (old.postPatch or "") + ''
    cp ${./portal/registry.rs} src/rutabaga_gfx/src/cross_domain/portal_registry.rs
    cp ${../../lib/transport/unix/stream.rs} src/rutabaga_gfx/src/cross_domain/sys/unix_stream.rs
  '';
})
