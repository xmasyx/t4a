#!/bin/zsh
# L'icona di T4A: la stessa trasmissione rovinata di NoSleep, in verde.
#
# Costruita e non generata da un modello, per la stessa ragione: le tre lettere devono uscire
# giuste per costruzione. Richiede ImageMagick, che NON serve per compilare l'app — l'icona finita
# e' committata in `Icon/icon-1024.png` e `build-app.sh` usa quella. Questo script serve a rifarla.
#
#   Scripts/icon.sh [uscita.png]
set -e
S=1024
FONT="/System/Library/Fonts/Helvetica.ttc"
OUT="${1:-Icon/icon-1024.png}"
T=$(mktemp -d)

# Geometria delle icone di sistema: 6% di margine, angoli al 22%. La stessa di NoSleep.
INSET=$((S * 6 / 100))
R=$((S * 22 / 100))
X2=$((S - INSET))

# --- il testo, una riga, come maschera -----------------------------------------
#
# `-kerning` aggiunge spazio anche DOPO l'ultima lettera, quindi una riga centrata risulta
# spostata a sinistra di mezzo kerning: si compensa di meta'.
magick -size ${S}x${S} xc:black -font "$FONT" -weight 700 \
  -fill white -gravity center \
  -pointsize 380 -kerning 18 -annotate +8+0 "T4A" "$T/t.png"

# --- i tre canali non si sovrappongono ------------------------------------------
magick "$T/t.png" -colorspace gray -roll +7+0 "$T/r.png"
magick "$T/t.png" -colorspace gray            "$T/g.png"
magick "$T/t.png" -colorspace gray -roll -7+2 "$T/b.png"
magick "$T/r.png" "$T/g.png" "$T/b.png" -combine -colorspace sRGB "$T/text.png"

# L'alone e' verde: e' da li' che l'icona prende il colore, mentre le lettere restano bianche
# al centro e leggibili a 16px.
magick "$T/text.png" \( +clone -blur 0x18 -fill "#3eff9b" -tint 100 -evaluate multiply 1.45 \) \
  -compose screen -composite "$T/text-glow.png"

# --- il lampo, dentro le lettere --------------------------------------------------
magick -size 520x520 radial-gradient:white-black -evaluate pow 3.2 \
  -fill "#3eff9b" -tint 100 "$T/halo.png"
magick -size 520x520 xc:black -fill white -draw "circle 260,260 260,240" \
  -blur 0x28 "$T/core.png"
magick -size 520x520 radial-gradient:white-black -evaluate pow 1.8 "$T/mask.png"
magick -size 520x520 xc:black -fill white \
  -draw "rectangle 256,34 264,486" -draw "rectangle 34,256 486,264" \
  -blur 0x7 "$T/spikes.png"
magick "$T/spikes.png" "$T/mask.png" -compose multiply -composite \
  -evaluate multiply 1.5 "$T/star.png"
magick "$T/halo.png" "$T/core.png" -compose screen -composite \
  "$T/star.png" -compose screen -composite "$T/flare.png"

magick -size ${S}x${S} xc:black \
  \( "$T/flare.png" -geometry +252+252 \) -compose screen -composite \
  \( "$T/text-glow.png" \) -compose screen -composite "$T/stage.png"

# --- scanline, grana, e la maschera del vetro -----------------------------------
magick -size 4x4 xc:"#ffffff" -fill "#a0a0a0" -draw "rectangle 0,0 3,1" \
  -write mpr:scan +delete -size ${S}x${S} tile:mpr:scan "$T/scan.png"
magick "$T/stage.png" "$T/scan.png" -compose multiply -composite \
  -attenuate 0.16 +noise Gaussian "$T/lit.png"

# Il quadro dell'icona: margine e angoli di sistema, con l'alfa vero fuori dal rettangolo.
magick -size ${S}x${S} xc:none -fill white \
  -draw "roundrectangle $INSET,$INSET $X2,$X2 $R,$R" "$T/shape.png"
mkdir -p "$(dirname "$OUT")"
magick "$T/lit.png" "$T/shape.png" -alpha off -compose copyopacity -composite \
  -depth 8 -strip -define png:compression-level=9 "$OUT"

echo "scritto: $OUT"
magick identify "$OUT"
rm -rf "$T"
