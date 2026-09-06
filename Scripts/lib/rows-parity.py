#  rows-parity.py — la barra contro il file, non contro sé stessa (ISC-172).
#
#  Sta in un file suo e non dentro `bench-rows.sh` per una ragione pratica e
#  una di sostanza. Pratica: un heredoc python dentro un heredoc bash si
#  chiude sul primo delimitatore che incontra, e il secondo pezzo di codice
#  sparisce senza che niente lo dica. Di sostanza: questo è il pezzo che deve
#  poter essere letto da solo, perché è il metro.
#
#  Il metro rifà il conto sulle stesse tre voci del transcript SENZA guardare
#  come lo fa l'app. Serve a separare due guasti che dall'esterno si
#  assomigliano: se questo conto e quello dell'adattatore divergono, la
#  lettura è sbagliata; se divergono l'adattatore e la barra, è sbagliata la
#  scrittura della cella.

import json
import os
import sys

d = json.load(open(sys.argv[1]))
dash = d['dash']
adapter = d['agents'][0]['adapter']

# Il file che l'adattatore sta seguendo, cercato nelle cartelle che dichiara
# di sorvegliare: il dump ne dà il nome, non il percorso.
name = adapter.get('following') or ''
path = None
for directory in adapter.get('watchedDirectories') or []:
    candidate = os.path.join(directory, name)
    if name and os.path.exists(candidate):
        path = candidate
        break
if not path:
    print("      il file seguito non è stato trovato: il polo NON misura niente")
    sys.exit(1)
print("      seguendo: %s" % path)

context = None
output = 0
effort = None
for line in open(path, errors='replace'):
    try:
        record = json.loads(line)
    except ValueError:
        continue
    # Un sotto-agente ha un contesto suo: contarlo qui sarebbe rispondere
    # con il numero di un'altra conversazione.
    if record.get('isSidechain') is True or record.get('type') != 'assistant':
        continue
    if isinstance(record.get('effort'), str) and record['effort']:
        effort = record['effort']
    usage = (record.get('message') or {}).get('usage') or {}
    if not usage:
        continue
    context = (usage.get('input_tokens', 0)
               + usage.get('cache_creation_input_tokens', 0)
               + usage.get('cache_read_input_tokens', 0))
    output += usage.get('output_tokens', 0)


def compact(count):
    if count < 1000:
        return str(count)
    if count < 1000000:
        thousands = count / 1000.0
        return ('%.1fk' % thousands) if thousands < 100 else ('%dk' % round(thousands))
    return '%.1fM' % (count / 1000000.0)


atteso = {
    'context': compact(context) if context is not None else '—',
    'output': compact(output) if output else '—',
    'effort': effort or '—',
}
grezzi = {'context': context, 'output': output, 'effort': effort}
bad = []
for key in ('context', 'output', 'effort'):
    got = dash['painted'].get(key)
    print("      %-8s barra %-10r  file %-10r  (grezzo: %s)"
          % (key, got, atteso[key], grezzi[key]))
    if got != atteso[key]:
        bad.append('%s: barra %r, file %r' % (key, got, atteso[key]))

# Il modello invece deve esserci: dopo una risposta il file lo porta sempre.
modello = dash['painted'].get('model')
print("      %-8s barra %r" % ('model', modello))
if modello in (None, '—'):
    bad.append('model è ancora un trattino dopo una risposta')

print("      grezzi dall'adattatore: context=%s output=%s effort=%r"
      % (adapter.get('contextTokens'), adapter.get('outputTokens'),
         adapter.get('effort')))
if adapter.get('contextTokens') != context:
    bad.append("l'adattatore legge %s, il file dice %s"
               % (adapter.get('contextTokens'), context))
if adapter.get('outputTokens') != output:
    bad.append("l'adattatore somma %s, il file fa %s"
               % (adapter.get('outputTokens'), output))

if bad:
    print("      SBAGLIATO: %s" % " · ".join(bad))
sys.exit(1 if bad else 0)
