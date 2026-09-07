package dev.crumb.core

import org.json.JSONArray
import org.json.JSONObject

/** Strictly bounded, opt-in static route metadata. Only known keys survive validation. */
internal object CrumbScreenContext {
    fun validate(json: String?): String? = runCatching {
        require(json != null && json.toByteArray().size <= 2048)
        val value = JSONObject(json)
        val source = value.getString("source")
        require(source in setOf("manual", "react_navigation", "expo_router"))
        fun label(value: String): String {
            require(value.isNotBlank() && value.toByteArray().size <= 128 &&
                !value.contains("://") && !value.contains('?') && !value.contains('#') &&
                value.none { Character.isISOControl(it) })
            return CrumbFailureText.sanitize(value).also { require(it.toByteArray().size <= 128) }
        }
        require(value.get("name") is String)
        val name = label(value.getString("name"))
        val route = value.getJSONArray("route")
        require(route.length() in 1..8)
        val names = JSONArray()
        for (index in 0 until route.length()) {
            require(route.get(index) is String)
            names.put(label(route.getString(index)))
        }
        JSONObject().put("name", name).put("route", names).put("source", source).toString()
    }.getOrNull()
}
