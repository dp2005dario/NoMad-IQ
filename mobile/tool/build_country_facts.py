#!/usr/bin/env python3
"""Genera assets/geo/country_facts.txt y assets/geo/fact_names.txt para la
pantalla "Antes de salir" (las tarjetas "<país> en 30 segundos").

Fuentes (se descargan a mano y se pasan como argumentos):
  1. REST Countries 3.1 (licencia MPL-2.0):
     https://raw.githubusercontent.com/restcountries/restcountries/master/src/main/resources/countriesV3.1.json
     -> lado de conducción, monedas e idiomas oficiales de cada país.
  2. Códigos de idioma (ISO 639-3 -> ISO 639-1), datasets/language-codes (ODC PDDL):
     https://raw.githubusercontent.com/datasets/language-codes/master/data/language-codes-full.csv
  3. CLDR de Unicode (licencia Unicode v3), los nombres de idiomas y monedas
     en los 25 idiomas de la app:
     https://raw.githubusercontent.com/unicode-org/cldr-json/main/cldr-json/cldr-localenames-full/main/<idioma>/languages.json
     https://raw.githubusercontent.com/unicode-org/cldr-json/main/cldr-json/cldr-numbers-full/main/<idioma>/currencies.json

Uso:
  python3 tool/build_country_facts.py countriesV3.1.json language-codes-full.csv carpeta_cldr

En carpeta_cldr: <idioma>-languages.json y <idioma>-currencies.json.

Formato de country_facts.txt (una línea por país):
  ES|R|EUR|es,ca,eu,gl
  ISO2 | L o R (lado por el que se conduce) | monedas | idiomas oficiales
Formato de fact_names.txt:
  L|ja|<nombre en es>|<en>|...   (idioma)
  C|JPY|¥|<nombre en es>|<en>|... (moneda, con su símbolo)
"""
import csv
import json
import os
import sys

LANGS = "es en ar bn de fa fil fr hi id it ja ko ms nl pl pt ro ru th tr uk ur vi zh".split()


def main(countries_path, codes_path, cldr_dir):
    countries = json.load(open(countries_path, encoding="utf-8"))
    to2 = {}
    with open(codes_path, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row["alpha2"]:
                to2[row["alpha3-b"]] = row["alpha2"]
                if row["alpha3-t"]:
                    to2[row["alpha3-t"]] = row["alpha2"]
    lang_names = {}
    cur_names = {}
    for lang in LANGS:
        ln = json.load(open(os.path.join(cldr_dir, f"{lang}-languages.json"), encoding="utf-8"))
        cn = json.load(open(os.path.join(cldr_dir, f"{lang}-currencies.json"), encoding="utf-8"))
        lang_names[lang] = next(iter(ln["main"].values()))["localeDisplayNames"]["languages"]
        cur_names[lang] = next(iter(cn["main"].values()))["numbers"]["currencies"]

    facts = []
    used_langs = {}
    used_curs = {}
    for c in sorted(countries, key=lambda c: c["cca2"]):
        iso = c["cca2"]
        side = (c.get("car") or {}).get("side")
        drive = {"left": "L", "right": "R"}.get(side, "")
        curs = sorted((c.get("currencies") or {}).keys())
        for code, info in (c.get("currencies") or {}).items():
            used_curs[code] = info.get("symbol", "")
        langs = []
        for code3 in (c.get("languages") or {}):
            code = to2.get(code3, code3)
            # Solo si CLDR sabe cómo se llama en español (si no, no se enseña).
            if code in lang_names["es"]:
                langs.append(code)
                used_langs[code] = True
        facts.append(f"{iso}|{drive}|{','.join(curs)}|{','.join(langs)}")

    out = os.path.join(os.path.dirname(__file__), "..", "assets", "geo")
    with open(os.path.join(out, "country_facts.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(facts) + "\n")
    rows = []
    for code in sorted(used_langs):
        rows.append("|".join(["L", code] + [lang_names[l].get(code, "") for l in LANGS]))
    for code in sorted(used_curs):
        names = [(cur_names[l].get(code) or {}).get("displayName", "") for l in LANGS]
        if not names[1]:
            continue
        rows.append("|".join(["C", code, used_curs[code]] + names))
    with open(os.path.join(out, "fact_names.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(rows) + "\n")
    print(len(facts), "países,", len(used_langs), "idiomas,", len(used_curs), "monedas")


if __name__ == "__main__":
    main(*sys.argv[1:4])
