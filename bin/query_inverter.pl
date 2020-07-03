#!/usr/bin/perl -w
#
# query_inverter.pl
# Read parameters from Kostal Plenticore Plus Inverters
#
# Copyright (C) 2020 Dieter Dobersberger <digdob@github.com>
# based on sunspec-monitor Copyright (C) 2017-2019 Timo Kokkonen <tjko@iki.fi>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 3
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor,
# Boston, MA  02110-1301, USA.
#
#

# use Data::HexDump;
use strict;
use Device::Modbus::TCP::Client;
use JSON;

our $CFG_HOST = "192.168.x.x"; # set to IP address of your inverter
our $CFG_PORT = xxx; # set to the port number
our $CFG_TIMEOUT = 10;
our $CFG_UNIT = x; # set your Modbus unit-id

sub float32(*){
    my ($data) = @_;

    my ($f_val)  = 0.0;

    if (unpack("N",$data) != 0) {
        my $bin_str = substr(unpack("B32",$data),16,16).substr(unpack("B32",$data),0,16);
        my $f_sgn  = substr($bin_str,0,1) == "1" ? -1 : 1;
        my $f_exp  = oct("0b".substr($bin_str,1,8));
        my $f_man  = 1+oct("0b".substr($bin_str,9,23))*(2**-23);
        $f_val  = $f_sgn * (2**($f_exp-127)) * $f_man;
    }

    return $f_val;
}

sub get_inverter_sunspec_block(*) {
    my ($ctx) = @_;
    my $req = $ctx->read_holding_registers(unit=>$CFG_UNIT,
        address=>40000,
        quantity=>69);

    $ctx->send_request($req) || die("get_inverter_sunspec_block send_request(): failed");

    my $adu = $ctx->receive_response();
    die("Read of Common block registers failed (device does not support SunSpec?)")
        unless ($adu->success);

    my $data = pack("n*",@{$adu->values});

    my $cb;
    $cb->{C_SunSpec_ID} = unpack("a4",substr($data,0,4));
    $cb->{C_SunSpec_DID} = unpack("n",substr($data,4,2));
    $cb->{C_SunSpec_Length} = unpack("n",substr($data,6,2));
    $cb->{C_Manufacturer} = unpack("a*",substr($data,8,32));
    $cb->{C_Manufacturer} =~ s/\0+$//;
    $cb->{C_Model} = unpack("a*",substr($data,40,32));
    $cb->{C_Model} =~ s/\0+$//;
    $cb->{C_Version} = unpack("a*",substr($data,88,16));
    $cb->{C_Version} =~ s/\0+$//;
    $cb->{C_SerialNumber} = unpack("a*",substr($data,104,32));
    $cb->{C_SerialNumber} =~ s/\0+$//;
    $cb->{C_DeviceAddress} = unpack("n",substr($data,136,2));

    die("Non SunSpec common block received (not SunSpec compliant device?)")
        unless ($cb->{C_SunSpec_ID} eq "SunS" && $cb->{C_SunSpec_DID} == 1);

    return $cb;
}

sub get_basic_consumption_block(*) {

    my ($ctx) = @_;
    my $req = $ctx->read_holding_registers(unit=>$CFG_UNIT,
        address=>100,
        quantity=>80);

    $ctx->send_request($req) || die("get_basic_consumption_block send_request(): failed");

    my $adu = $ctx->receive_response();
    die("Read of Common block registers failed (device does not support SunSpec?)")
        unless ($adu->success);

    my $data = pack("n*",@{$adu->values});

    #	print "DUMP\n";
    #	print HexDump($data);
    #	print "END DUMP\n";

    my $cb;
    $cb->{Total_DC_power} = float32(substr($data, 0, 4));
    $cb->{State_of_energy_manager} = float32(substr($data, 8, 4));

    # Watts
    $cb->{Home_consumption_from_battery} = float32(substr($data, 12, 4));
    $cb->{Home_consumption_from_grid} = float32(substr($data, 16, 4));
    $cb->{Home_consumption_from_PV} = float32(substr($data, 32, 4));

    # Watthours
    $cb->{Total_home_consumption_Battery} = float32(substr($data, 20, 4));
    $cb->{Total_home_consumption_Grid} = float32(substr($data, 24, 4));
    $cb->{Total_home_consumption_PV} = float32(substr($data, 28, 4));
    $cb->{Total_home_consumption} = float32(substr($data, 36, 4));

    # Percent
    $cb->{Total_home_consumption_rate} = float32(substr($data, 48, 4));

    $cb->{Grid_frequency} = float32(substr($data, 104, 4));
    $cb->{Current_Phase_1} = float32(substr($data, 108, 4));
    $cb->{Active_power_Phase_1} = float32(substr($data, 112, 4));
    $cb->{Voltage_Phase_1} = float32(substr($data,116, 4));
    $cb->{Current_Phase_2} = float32(substr($data,120, 4));
    $cb->{Active_power_Phase_2} = float32(substr($data, 124, 4));
    $cb->{Voltage_Phase_2} = float32(substr($data, 128, 4));
    $cb->{Current_Phase_3} = float32(substr($data, 132, 4));
    $cb->{Active_power_Phase_3} = float32(substr($data, 136, 4));
    $cb->{Voltage_Phase_3} = float32(substr($data, 140, 4));
    $cb->{Total_AC_active_power} = float32(substr($data, 144, 4));
    $cb->{Total_AC_reactive_power} = float32(substr($data, 148, 4));
    $cb->{Total_AC_apparent_power} = float32(substr($data, 156, 4));

    # calculate total yield:
    # 1) add own consumption from PV and battery
    # 2) convert own consumption rate from percent (67%) to ratio (0.67)
    # 3) calculate total yield by dividing own consumption by ratio
    $cb->{Total_yield} = ($cb->{Total_home_consumption_Battery} + $cb->{Total_home_consumption_PV}) / ($cb->{Total_home_consumption_rate} / 100);

    # calculate grid purchase / feed-in
    # generated power by inverter
    # minus power used by home from PV
    # battery can be ignored (i guess if my math doesn't suck too much)
    # positive value is purchase
    # negative value is feed-in
    $cb->{Grid_Power} = $cb->{Home_consumption_from_PV} + $cb->{Home_consumption_from_battery} + $cb->{Home_consumption_from_grid} - $cb->{Total_AC_active_power};

    return $cb;

}

sub get_battery_stats(*) {

    my ($ctx) = @_;
    my $req = $ctx->read_holding_registers(unit=>$CFG_UNIT,
        address=>190,
        quantity=>54);

    $ctx->send_request($req) || die("get_battery_stats send_request(): failed");

    my $adu = $ctx->receive_response();
    die("Read of Common block registers failed (device does not support SunSpec?)")
        unless ($adu->success);

    my $data = pack("n*",@{$adu->values});

    #	print "DUMP\n";
    #	print HexDump($data);
    #	print "END DUMP\n";

    my $cb;
    $cb->{Number_of_battery_cycles} = float32(substr($data, 8, 4));
    $cb->{Actual_Battery_current} = float32(substr($data, 20, 4));
    $cb->{Battery_powerflow} = ($cb->{Actual_Battery_current} <= 0) ? 'charging' : 'discharging';
    $cb->{state_of_charge} = float32(substr($data, 40, 4));
    $cb->{Battery_temperature} = float32(substr($data, 48, 4));
    $cb->{Battery_voltage} = float32(substr($data, 52, 4));

    return $cb;

}

sub get_dc_stats(*) {

    my ($ctx) = @_;
    my $req = $ctx->read_holding_registers(unit=>$CFG_UNIT,
        address=>258,
        quantity=>30);

    $ctx->send_request($req) || die("get_dc_stats send_request(): failed");

    my $adu = $ctx->receive_response();
    die("Read of Common block registers failed (device does not support SunSpec?)")
        unless ($adu->success);

    my $data = pack("n*",@{$adu->values});

    #	print "DUMP\n";
    #	print HexDump($data);
    #	print "END DUMP\n";

    my $cb;
    $cb->{Current_DC1} = float32(substr($data, 0, 4));
    $cb->{Power_DC1} = float32(substr($data, 4, 4));
    $cb->{Voltage_DC1} = float32(substr($data, 16, 4));
    $cb->{Current_DC2} = float32(substr($data, 20, 4));
    $cb->{Power_DC2} = float32(substr($data, 24, 4));
    $cb->{Voltage_DC2} = float32(substr($data, 36, 4));
    $cb->{Current_DC3} = float32(substr($data, 40, 4));
    $cb->{Power_DC3} = float32(substr($data, 44, 4));
    $cb->{Voltage_DC3} = float32(substr($data, 56, 4));

    return $cb;

}

sub get_basic_info(*) {

    my ($ctx) = @_;
    my $req = $ctx->read_holding_registers(unit=>$CFG_UNIT,
        address=>6,
        quantity=>52);

    $ctx->send_request($req) || die("get_basic_info send_request(): failed");

    my $adu = $ctx->receive_response();
    die("Read of Common block registers failed (device does not support SunSpec?)")
        unless ($adu->success);

    my $data = pack("n*",@{$adu->values});

    #	print "DUMP\n";
    #	print HexDump($data);
    #	print "END DUMP\n";

    my $cb;
    $cb->{Inverter_article_number} = unpack("a*",substr($data,0,16));
    $cb->{Inverter_article_number} =~ s/\0+$//;
    $cb->{Inverter_serial_number} = unpack("a*",substr($data,16,16));
    $cb->{Inverter_serial_number} =~ s/\0+$//;
    $cb->{Software_Version_Maincontroller} = unpack("a*",substr($data,64,16));
    $cb->{Software_Version_Maincontroller} =~ s/\0+$//;
    $cb->{Software_Version_IO_Controller} = unpack("a*",substr($data,80,16));
    $cb->{Software_Version_IO_Controller} =~ s/\0+$//;
    $cb->{Inverter_state} = unpack("n",substr($data,100,2));

    return $cb;

}


# MAIN

my $modbusClient;
my $inverterInfo;

$modbusClient = Device::Modbus::TCP::Client->new(host=>$CFG_HOST,port=>$CFG_PORT,timeout=>$CFG_TIMEOUT);

$inverterInfo->{basic_info} = get_basic_info($modbusClient);
$inverterInfo->{basic_consumption} = get_basic_consumption_block($modbusClient);
$inverterInfo->{dc_stats} = get_dc_stats($modbusClient);
$inverterInfo->{battery_stats} = get_battery_stats($modbusClient);

print to_json($inverterInfo);

$modbusClient->disconnect;
exit(0);
