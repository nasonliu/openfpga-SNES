# Published AS6C2016-55BIN capacitance maxima. This is a device-load model,
# not a measured PCB trace/load model. Only the isolated state profile owns it.
proc configure_savestate_sram_load {enabled} {
 set tag SAVESTATE_SRAM_DEVICE_LOAD_V1
 set control {sram_we_n sram_oe_n sram_ub_n sram_lb_n}
 for {set i 0} {$i<17} {incr i} {lappend control [format {sram_a[%d]} $i]}
 set data {}
 for {set i 0} {$i<16} {incr i} {lappend data [format {sram_dq[%d]} $i]}
 set choices [list [list 6P $control] [list 8P $data]]
 foreach choice $choices {
  lassign $choice desired pins
  foreach_in_collection a [get_all_instance_assignments -name BOARD_MODEL_FAR_C] {
   lassign $a section from to name value entity actual_tag
   if {$to ni $pins || $from ne ""} {continue}
   if {$actual_tag eq $tag && ![string equal -nocase $value $desired]} {error "Edited state SRAM load: $to $value"}
   if {$enabled && $actual_tag ne $tag} {error "Existing unowned SRAM load: $to $value"}
  }
 }
 foreach choice $choices {
  lassign $choice desired pins
  foreach_in_collection a [get_all_instance_assignments -name BOARD_MODEL_FAR_C -tag $tag] {
   lassign $a section from to name value entity actual_tag
   if {$to in $pins && $from eq "" && [string equal -nocase $value $desired]} {
    set_instance_assignment -name BOARD_MODEL_FAR_C $desired -to $to -tag $tag -remove
   }
  }
  if {$enabled} {foreach pin $pins {set_instance_assignment -name BOARD_MODEL_FAR_C $desired -to $pin -tag $tag}}
 }
}
