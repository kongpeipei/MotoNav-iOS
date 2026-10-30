package com.motonav.app.ui

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.recyclerview.widget.RecyclerView
import com.motonav.app.databinding.ItemPoiBinding
import com.motonav.app.data.Poi

class PoiAdapter(
    private var items: List<Poi>,
    private val onToggle: (Long, Boolean) -> Unit,
    private val onClick: (Poi) -> Unit
) : RecyclerView.Adapter<PoiAdapter.Holder>() {

    fun submit(list: List<Poi>) {
        items = list
        notifyDataSetChanged()
    }

    inner class Holder(val binding: ItemPoiBinding) : RecyclerView.ViewHolder(binding.root)

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Holder {
        val binding = ItemPoiBinding.inflate(LayoutInflater.from(parent.context), parent, false)
        return Holder(binding)
    }

    override fun onBindViewHolder(holder: Holder, position: Int) {
        val p = items[position]
        val b = holder.binding
        b.dotColor.setBackgroundColor(p.type.color)
        b.tvName.text = p.name
        b.tvSub.text = "${p.type.label} · 半径${p.radiusM.toInt()}m"
        b.chkEnabled.isChecked = p.enabled
        b.chkEnabled.setOnCheckedChangeListener { _, checked -> onToggle(p.id, checked) }
        b.root.setOnClickListener { onClick(p) }
    }

    override fun getItemCount(): Int = items.size
}
