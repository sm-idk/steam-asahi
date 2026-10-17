@0xe2c8119d425541f3;

interface Lease {
  ready @0 (peer :Lease) -> ();
  close @1 () -> ();
}

interface Peer {
  connect @0 (peer :Peer) -> ();
  message @1 (data :Data) -> ();
  eof @2 () -> ();
  file @3 (data :Data, manifest :Data) -> ();
  pipeWire @4 (data :Data, session :Text, owner :Text, token :Data,
               lease :Lease) -> (accepted :Bool);
}

struct Variable {
  name @0 :Text;
  value @1 :Text;
}

interface Desktop {
  health @0 () -> (status :Text, executable :Text);
  open @1 (target :Text, environment :List(Variable)) -> (status :Int16);
  resolve @2 (target :Text, mode :Text) -> (uri :Text, kind :Text);
  cacheIcon @3 (data :Data) -> (uri :Text);
}
