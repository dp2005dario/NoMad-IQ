"""Reparto de tareas de un viaje en grupo.

    GET    /v1/group-negotiations/{id}/tasks                 la lista
    POST   /v1/group-negotiations/{id}/tasks                 añadir una ("Reservar el hotel")
    PUT    /v1/group-negotiations/{id}/tasks/{task}/take     "me encargo yo" (o soltarla)
    PUT    /v1/group-negotiations/{id}/tasks/{task}/done     hecha / no hecha
    DELETE /v1/group-negotiations/{id}/tasks/{task}          quitarla (quien la puso o el organizador)

Coste 0 €: solo PostgreSQL, con tope de 40 tareas por viaje. A quien no es
del viaje se le responde 404.
"""
