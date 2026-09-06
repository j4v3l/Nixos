# Compatibility view for tools which read the original laptop identity.
(builtins.fromJSON (builtins.readFile ../hosts/laptop/settings.json)).identity
