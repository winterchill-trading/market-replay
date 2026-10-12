(lang dune 3.17)

(name market-replay)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/market-replay))

(package
 (name market-replay)
 (synopsis
  "Replay server for recorded raw market data over HTTP and venue-native websockets")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  cohttp
  cohttp-async
  async_websocket
  market-data
  hl-protocol
  binance-protocol
  bybit-protocol
  ppx_jane
  ppx_yojson_conv
  yojson
  uri
  (hl-client :with-test)
  (binance-client :with-test)
  (bybit-client :with-test)
  (okx-feed :with-test)
  (coinbase-feed :with-test)
  (kraken-feed :with-test)
  (deribit-feed :with-test)
  (bitget-feed :with-test)))
