# Installation

## Setup mediKanren-MCP

Somewhere, let's say `$MEDIKANREN`:

```sh
git clone https://github.com/webyrd/mediKanren.git
cd mediKanren
cd contrib/medikanren2/neo/
git clone https://github.com/CHARM-BDF/mediKanren-MCP.git
cd ../../../../ # go to top-level mediKanren directory
cd medikanren2/neo/neo-data
# install the knowledge graphs here
```

## Testing mediKanren-MCP

From the `mediKanren-MCP` directory, e.g., `$MEDIKANREN/contrib/medikanren2/neo/mediKanren-MCP`.

In one terminal:
```sh
racket server.rkt
```

If you get the error:
```
tcp-listen: listen failed
  hostname: 127.0.0.1
  port number: 8080
  system error: Address already in use; errno=48
```
then someone is already using port 8080 -- maybe someone is already running the server? Try to continue with the next steps, assuming that's the case (you can also try the Racket server as explained in its own section below).
 
## Testing the Racket server

Try this URL:
http://localhost:8080/query?e1=Known-%3EX&e2=biolink%3Atreats&e3=CHEBI%3A45783

For example:
```sh
curl 'http://localhost:8080/query?e1=Known-%3EX&e2=biolink%3Atreats&e3=CHEBI%3A45783'
```

## Fine-tuning the Racket server

If the server runs into this error: `system error: Too many open files; errno=24`,
look at `ulimit -a`. mediKanren developers recommend setting the limit of file descriptors high, e.g. `ulimit -n 4096`.
