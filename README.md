# mediKanren-MCP

## [Setup](INSTALL.md)

## Installation

Install Racket. Then install dependencies: `raco pkg install yaml`.

## Run

Run `racket server.rkt`.

The Racket server runs on port 8080 by default. To use a different port set the environment variable `LLM_MEDIKANREN_PORT` on both terminals where you are running the Racket server and the Python script, e.g.:
```python
export LLM_MEDIKANREN_PORT=7070
```

Pro tip: use `rlwrap`, for the REPL to be smart.

You can create an external tunnel for a server with `lt --port $PORT--subdomain $SUBDOMAIN`. Then you get an URL like `https://$SUBDOMAIN.loca.lt`. You can prefix the command with `./retry.sh` to keep requesting the tunnel when there is a failure.

## Automatically running server and tunnel

You can use the `npm` command `pm2` to restart the server and tunnel automatically if needed.

Cheatsheet:
- `pm2 start $CMD --name $NAME -- $CMD_ARGS`
  - `pm2 start racket --name racket-medikanren -- server.rkt`
  - `pm2 start lt --name localtunnel-medikanren  -- --port 8080 --subdomain medikanren --wait-ready` 
- `pm2 startup`
- `pm2 save`
- `pm2 logs`

## Using Cloudflare instead of localtunnel

TODO

## Model Context Protocol server

TODO
