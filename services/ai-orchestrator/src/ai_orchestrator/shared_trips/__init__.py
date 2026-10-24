"""Copia este viaje: compartir un viaje con un código y que Flyra lo adapte.

Qué hace: alguien comparte su viaje (título, destino, días y una lista de
cosas con su precio) y le damos un código de 8 letras. Quien tenga el código
lo ve, lo copia a sus viajes (en su móvil) y, si su presupuesto es menor,
Flyra propone cambios más baratos línea a línea.

Coste 0 €: PostgreSQL para guardarlos, el modelo es nuestro con cupo diario
por persona, y las adaptaciones se guardan en Redis una semana: si mil
personas copian el mismo viaje con el mismo presupuesto, el modelo trabaja
una vez.
"""
