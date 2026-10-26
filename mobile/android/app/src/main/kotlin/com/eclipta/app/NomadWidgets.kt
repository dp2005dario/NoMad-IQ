package com.eclipta.app

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Color
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

// Los widgets del escritorio de Android (maqueta "Widgets").
//
// La app (en Dart) ya deja preparados y TRADUCIDOS todos los textos que el
// widget enseñará en cada momento: una lista de "fotos fijas" con la hora a
// partir de la cual vale cada una. Aquí solo se elige la que toca ahora y se
// pinta. Así el widget va cambiando solo (antes del vuelo → en vuelo →
// has llegado) aunque la app esté cerrada y sin Internet, y no hace falta
// ningún servidor: Android lo despierta a esas horas (HomeWidgetScheduler).
//
// Formato de cada foto fija (JSON):
//   {"t": milisegundos desde 1970, "tag": "EN VUELO · 46 %", "title": "MAD → HND",
//    "big": "7 h 40", "small": "Llegas a las 10:15", "pct": 46, "color": "#3DDC97"}
// "pct" = -1 → sin barra. {"t": ..., "empty": true} → ya no hay nada que enseñar.

abstract class NomadWidget(private val key: String) : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val snap = pick(widgetData.getString(key, null), System.currentTimeMillis())
        val empty = widgetData.getString("${key}_empty", null) ?: ""
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.nomad_widget)
            if (snap == null) {
                // Nada que enseñar: solo la frase "Abre ECLIPTA y añade tu vuelo".
                views.setViewVisibility(R.id.widget_content, View.GONE)
                views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
                views.setTextViewText(R.id.widget_empty, empty)
            } else {
                views.setViewVisibility(R.id.widget_content, View.VISIBLE)
                views.setViewVisibility(R.id.widget_empty, View.GONE)
                views.setTextViewText(R.id.widget_tag, snap.optString("tag"))
                views.setTextViewText(R.id.widget_title, snap.optString("title"))
                views.setTextViewText(R.id.widget_big, snap.optString("big"))
                views.setTextViewText(R.id.widget_small, snap.optString("small"))
                views.setTextColor(R.id.widget_tag, color(snap.optString("color")))
                val pct = snap.optInt("pct", -1)
                if (pct in 0..100) {
                    views.setViewVisibility(R.id.widget_progress, View.VISIBLE)
                    views.setProgressBar(R.id.widget_progress, 100, pct, false)
                } else {
                    views.setViewVisibility(R.id.widget_progress, View.GONE)
                }
            }
            // Tocar el widget abre la app (sin enlace: la app decide qué enseñar).
            views.setOnClickPendingIntent(
                R.id.widget_root,
                HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java),
            )
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    companion object {
        private const val MINT = "#3DDC97"

        /** La última foto fija cuya hora ya ha llegado; null si no hay o es "vacía". */
        fun pick(raw: String?, now: Long): JSONObject? {
            if (raw.isNullOrEmpty()) return null
            return try {
                val list = JSONArray(raw)
                var best: JSONObject? = null
                var bestT = Long.MIN_VALUE
                for (i in 0 until list.length()) {
                    val s = list.optJSONObject(i) ?: continue
                    val t = s.optLong("t", Long.MAX_VALUE)
                    if (t <= now && t >= bestT) {
                        best = s
                        bestT = t
                    }
                }
                if (best == null || best.optBoolean("empty", false)) null else best
            } catch (e: JSONException) {
                // Un dato roto no debe romper el escritorio: se enseña vacío.
                null
            }
        }

        private fun color(hex: String): Int =
            try {
                Color.parseColor(if (hex.matches(Regex("^#[0-9A-Fa-f]{6}$"))) hex else MINT)
            } catch (e: IllegalArgumentException) {
                Color.parseColor(MINT)
            }
    }
}

/** Tu vuelo: antes (sal de casa, embarque), en vuelo (cuánto falta) y al llegar. */
class FlightWidget : NomadWidget("flight")

/** El chollo de hoy desde tu aeropuerto. */
class DealWidget : NomadWidget("deal")

/** Cuánto te queda hoy del presupuesto del viaje. */
class BudgetWidget : NomadWidget("budget")
