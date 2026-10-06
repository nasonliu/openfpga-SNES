set assignments {}
proc foreach_in_collection {var collection body} {upvar 1 $var a;foreach a $collection {uplevel 1 $body}}
proc get_all_instance_assignments {args} {
 global assignments
 if {[lsearch $args -tag]<0} {return $assignments}
 set tag [lindex $args [expr {[lsearch $args -tag]+1}]];set out {}
 foreach a $assignments {if {[lindex $a 6] eq $tag} {lappend out $a}}
 return $out
}
proc set_instance_assignment {args} {
 global assignments
 set name [lindex $args 1];set value [lindex $args 2];set to [lindex $args [expr {[lsearch $args -to]+1}]];set tag [lindex $args [expr {[lsearch $args -tag]+1}]]
 set a [list {} {} $to $name $value {} $tag]
 if {[lsearch $args -remove]>=0} {set i [lsearch -exact $assignments $a];if {$i>=0} {set assignments [lreplace $assignments $i $i]}} else {lappend assignments $a}
}
source target/pocket/savestate_sram_load.tcl
configure_savestate_sram_load 1
if {[llength $assignments]!=37} {error "not37"}
configure_savestate_sram_load 1
if {[llength $assignments]!=37} {error "not idempotent"}
configure_savestate_sram_load 0
if {[llength $assignments]!=0} {error "did not remove own loads"}
set assignments [list [list {} {} sram_oe_n BOARD_MODEL_FAR_C 3P {} USER]]
configure_savestate_sram_load 0
if {[llength $assignments]!=1} {error "removed user load"}
if {![catch {configure_savestate_sram_load 1}]} {error "overwrote user load"}
puts "PASS 37 device loads, idempotent, stable removes owned only, conflict rejected"
