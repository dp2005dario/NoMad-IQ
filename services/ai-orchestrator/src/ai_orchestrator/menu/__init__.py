"""Traductor de cartas de restaurante (pantalla "Menú" de la app).

Qué hace: el móvil hace una foto de la carta, lee el texto DENTRO del
teléfono (ML Kit, gratis y sin red) y manda aquí solo las líneas de texto.
Flyra (el modelo que corre en nuestro servidor) devuelve, para cada plato:
qué es en tu idioma, una frase corta de qué lleva, un aviso si suele tener
alérgenos frecuentes y cómo pedirlo en el idioma del sitio.

Coste 0 €: el modelo es nuestro, así que lo que se controla es el tiempo de
máquina. Hay cupo diario por persona (como el chat de Flyra), un máximo de
líneas por carta y un tiempo máximo de respuesta.

La foto nunca sale del móvil y el texto de la carta no se guarda ni se
escribe en los registros.
"""
