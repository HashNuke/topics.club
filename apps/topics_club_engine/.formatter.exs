[
  import_deps: [:ecto, :oban],
  subdirectories: ["priv/*/migrations"],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
