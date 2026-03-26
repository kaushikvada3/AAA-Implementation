#include "ns3/command-line.h"
#include "ns3/config.h"
#include "ns3/double.h"
#include "ns3/internet-stack-helper.h"
#include "ns3/ipv4-address-helper.h"
#include "ns3/log.h"
#include "ns3/mobility-helper.h"
#include "ns3/rng-seed-manager.h"
#include "ns3/socket.h"
#include "ns3/string.h"
#include "ns3/wifi-helper.h"
#include "ns3/wifi-mac-helper.h"
#include "ns3/yans-wifi-channel.h"
#include "ns3/yans-wifi-helper.h"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <vector>

using namespace ns3;

namespace
{

std::vector<uint8_t> g_bobReceived;
std::vector<uint8_t> g_eveReceived;
Ptr<Socket> g_sourceSocket;
uint32_t g_packetSize;
uint32_t g_numPackets;
Time g_interval;
uint32_t g_nextSequence = 0;

uint32_t
ReadSequence(Ptr<Packet> packet)
{
    uint8_t buffer[4] = {0, 0, 0, 0};
    packet->CopyData(buffer, sizeof(buffer));
    return static_cast<uint32_t>(buffer[0]) |
           (static_cast<uint32_t>(buffer[1]) << 8) |
           (static_cast<uint32_t>(buffer[2]) << 16) |
           (static_cast<uint32_t>(buffer[3]) << 24);
}

void
ReceivePacket(Ptr<Socket> socket, std::vector<uint8_t>* received)
{
    while (Ptr<Packet> packet = socket->Recv())
    {
        if (packet->GetSize() < 4)
        {
            continue;
        }

        const uint32_t sequence = ReadSequence(packet);
        if (sequence < received->size())
        {
            (*received)[sequence] = 1;
        }
    }
}

void
ReceivePacketBob(Ptr<Socket> socket)
{
    ReceivePacket(socket, &g_bobReceived);
}

void
ReceivePacketEve(Ptr<Socket> socket)
{
    ReceivePacket(socket, &g_eveReceived);
}

void
SendPacket()
{
    if (g_nextSequence >= g_numPackets)
    {
        g_sourceSocket->Close();
        return;
    }

    std::vector<uint8_t> payload(g_packetSize, 0);
    payload[0] = static_cast<uint8_t>(g_nextSequence & 0xFF);
    payload[1] = static_cast<uint8_t>((g_nextSequence >> 8) & 0xFF);
    payload[2] = static_cast<uint8_t>((g_nextSequence >> 16) & 0xFF);
    payload[3] = static_cast<uint8_t>((g_nextSequence >> 24) & 0xFF);
    for (uint32_t index = 4; index < g_packetSize; ++index)
    {
        payload[index] = static_cast<uint8_t>((g_nextSequence * 37u + index * 13u) & 0xFF);
    }

    g_sourceSocket->Send(Create<Packet>(payload.data(), payload.size()));
    ++g_nextSequence;

    if (g_nextSequence < g_numPackets)
    {
        Simulator::Schedule(g_interval, &SendPacket);
    }
}

void
WriteRoundCsv(const std::string& outputPath, double eveDistance)
{
    std::ofstream out(outputPath, std::ios::trunc);
    out << "engine,distance_m,round,bob_received,eve_received,secure_round,"
           "key_secure_after_round,cumulative_bob_rx,cumulative_secure_rounds,cumulative_equivocation\n";

    uint32_t cumulativeBob = 0;
    uint32_t cumulativeSecure = 0;
    for (uint32_t round = 0; round < g_numPackets; ++round)
    {
        cumulativeBob += g_bobReceived[round];
        const uint32_t secureRound = g_bobReceived[round] && !g_eveReceived[round];
        cumulativeSecure += secureRound;
        const double muHat = cumulativeBob ? static_cast<double>(cumulativeSecure) / cumulativeBob : 0.0;
        const double equivocation =
            cumulativeBob ? 1.0 - std::pow(1.0 - muHat, static_cast<double>(cumulativeBob)) : 0.0;

        out << "ns3," << std::fixed << std::setprecision(1) << eveDistance << "," << (round + 1) << ","
            << static_cast<uint32_t>(g_bobReceived[round]) << "," << static_cast<uint32_t>(g_eveReceived[round])
            << "," << secureRound << "," << (cumulativeSecure > 0 ? 1 : 0) << "," << cumulativeBob << ","
            << cumulativeSecure << "," << std::setprecision(6) << equivocation << "\n";
    }
}

} // namespace

int
main(int argc, char* argv[])
{
    std::string phyMode = "DsssRate11Mbps";
    double bobDistance = 18.0;
    double eveDistance = 60.0;
    uint32_t packetSize = 512;
    uint32_t numPackets = 400;
    double intervalMs = 10.0;
    double txPowerDbm = -3.0;
    double pathLossExponent = 2.35;
    double referenceLoss = 40.0893182554;
    uint32_t seed = 1;
    uint32_t run = 1;
    std::string outputCsv = "aaa_ns3_rounds.csv";

    CommandLine cmd(__FILE__);
    cmd.AddValue("phyMode", "802.11 data/control mode for unicast and broadcast frames", phyMode);
    cmd.AddValue("bobDistance", "Alice-to-Bob distance in meters", bobDistance);
    cmd.AddValue("eveDistance", "Alice-to-Eve distance in meters", eveDistance);
    cmd.AddValue("packetSize", "Payload size in bytes", packetSize);
    cmd.AddValue("numPackets", "Number of packets to transmit", numPackets);
    cmd.AddValue("intervalMs", "Inter-packet interval in milliseconds", intervalMs);
    cmd.AddValue("txPowerDbm", "Transmit power in dBm", txPowerDbm);
    cmd.AddValue("pathLossExponent", "Log-distance path loss exponent", pathLossExponent);
    cmd.AddValue("referenceLoss", "Reference loss at 1 meter in dB", referenceLoss);
    cmd.AddValue("seed", "ns-3 RNG seed", seed);
    cmd.AddValue("run", "ns-3 RNG run number", run);
    cmd.AddValue("outputCsv", "Full path to the output CSV", outputCsv);
    cmd.Parse(argc, argv);

    g_packetSize = packetSize;
    g_numPackets = numPackets;
    g_interval = MilliSeconds(intervalMs);
    g_bobReceived.assign(g_numPackets, 0);
    g_eveReceived.assign(g_numPackets, 0);

    RngSeedManager::SetSeed(seed);
    RngSeedManager::SetRun(run);

    Config::SetDefault("ns3::WifiRemoteStationManager::NonUnicastMode", StringValue(phyMode));

    NodeContainer nodes;
    nodes.Create(3);

    WifiHelper wifi;
    wifi.SetStandard(WIFI_STANDARD_80211b);
    wifi.SetRemoteStationManager("ns3::ConstantRateWifiManager",
                                 "DataMode",
                                 StringValue(phyMode),
                                 "ControlMode",
                                 StringValue(phyMode));

    WifiMacHelper wifiMac;
    wifiMac.SetType("ns3::AdhocWifiMac");

    YansWifiPhyHelper wifiPhy;
    wifiPhy.Set("TxPowerStart", DoubleValue(txPowerDbm));
    wifiPhy.Set("TxPowerEnd", DoubleValue(txPowerDbm));
    wifiPhy.Set("RxGain", DoubleValue(0.0));

    YansWifiChannelHelper wifiChannel;
    wifiChannel.SetPropagationDelay("ns3::ConstantSpeedPropagationDelayModel");
    wifiChannel.AddPropagationLoss("ns3::LogDistancePropagationLossModel",
                                   "Exponent",
                                   DoubleValue(pathLossExponent),
                                   "ReferenceDistance",
                                   DoubleValue(1.0),
                                   "ReferenceLoss",
                                   DoubleValue(referenceLoss));
    wifiChannel.AddPropagationLoss("ns3::NakagamiPropagationLossModel",
                                   "Distance1",
                                   DoubleValue(40.0),
                                   "Distance2",
                                   DoubleValue(80.0),
                                   "m0",
                                   DoubleValue(1.5),
                                   "m1",
                                   DoubleValue(0.9),
                                   "m2",
                                   DoubleValue(0.75));
    wifiPhy.SetChannel(wifiChannel.Create());

    NetDeviceContainer devices = wifi.Install(wifiPhy, wifiMac, nodes);

    MobilityHelper mobility;
    Ptr<ListPositionAllocator> positions = CreateObject<ListPositionAllocator>();
    positions->Add(Vector(0.0, 0.0, 0.0));
    positions->Add(Vector(bobDistance, 0.0, 0.0));
    positions->Add(Vector(eveDistance, 0.0, 0.0));
    mobility.SetPositionAllocator(positions);
    mobility.SetMobilityModel("ns3::ConstantPositionMobilityModel");
    mobility.Install(nodes);

    InternetStackHelper internet;
    internet.Install(nodes);

    Ipv4AddressHelper ipv4;
    ipv4.SetBase("10.1.1.0", "255.255.255.0");
    ipv4.Assign(devices);

    const TypeId socketType = TypeId::LookupByName("ns3::UdpSocketFactory");
    Ptr<Socket> bobSocket = Socket::CreateSocket(nodes.Get(1), socketType);
    Ptr<Socket> eveSocket = Socket::CreateSocket(nodes.Get(2), socketType);
    InetSocketAddress local(Ipv4Address::GetAny(), 4444);
    bobSocket->Bind(local);
    eveSocket->Bind(local);
    bobSocket->SetRecvCallback(MakeCallback(&ReceivePacketBob));
    eveSocket->SetRecvCallback(MakeCallback(&ReceivePacketEve));

    g_sourceSocket = Socket::CreateSocket(nodes.Get(0), socketType);
    g_sourceSocket->SetAllowBroadcast(true);
    g_sourceSocket->Connect(InetSocketAddress(Ipv4Address("255.255.255.255"), 4444));

    Simulator::Schedule(Seconds(1.0), &SendPacket);
    Simulator::Stop(Seconds(1.0) + g_interval * g_numPackets + Seconds(0.5));
    Simulator::Run();
    Simulator::Destroy();

    WriteRoundCsv(outputCsv, eveDistance);
    return 0;
}
