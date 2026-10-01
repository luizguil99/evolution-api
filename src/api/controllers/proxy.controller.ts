import { InstanceDto } from '@api/dto/instance.dto';
import { ProxyDto } from '@api/dto/proxy.dto';
import { PrismaRepository } from '@api/repository/repository.service';
import { WAMonitoringService } from '@api/services/monitor.service';
import { ProxyService } from '@api/services/proxy.service';
import { ConfigService, Proxy } from '@config/env.config';
import { Logger } from '@config/logger.config';
import { BadRequestException, NotFoundException } from '@exceptions';
import { makeProxyAgent } from '@utils/makeProxyAgent';
import { proxyPoolKey } from '@utils/proxy-pool';
import axios from 'axios';

const logger = new Logger('ProxyController');

export class ProxyController {
  constructor(
    private readonly proxyService: ProxyService,
    private readonly waMonitor: WAMonitoringService,
    private readonly prismaRepository: PrismaRepository,
    private readonly configService: ConfigService,
  ) {}

  /**
   * Status of PROXY_POOL: which entries are free and which instance uses each one.
   * Passwords are never returned.
   */
  public async poolStatus() {
    const pool = this.configService.get<Proxy>('PROXY').POOL || [];

    const assigned = await this.prismaRepository.proxy.findMany({
      where: { enabled: true },
      select: {
        host: true,
        port: true,
        protocol: true,
        username: true,
        Instance: { select: { name: true, connectionStatus: true, ownerJid: true } },
      },
    });

    const byKey = new Map(assigned.map((p) => [proxyPoolKey(p), p]));
    const poolKeys = new Set(pool.map((entry) => proxyPoolKey(entry)));

    const proxies = pool.map((entry) => {
      const usedBy = byKey.get(proxyPoolKey(entry));
      return {
        host: entry.host,
        port: entry.port,
        protocol: entry.protocol,
        username: entry.username,
        inUse: !!usedBy,
        instanceName: usedBy?.Instance?.name ?? null,
        connectionStatus: usedBy?.Instance?.connectionStatus ?? null,
        ownerJid: usedBy?.Instance?.ownerJid ?? null,
      };
    });

    // Instances whose proxy is not part of the current pool (e.g. old proxies removed from PROXY_POOL)
    const outsidePool = assigned
      .filter((p) => !poolKeys.has(proxyPoolKey(p)))
      .map((p) => ({
        host: p.host,
        port: p.port,
        protocol: p.protocol,
        username: p.username,
        instanceName: p.Instance?.name ?? null,
        connectionStatus: p.Instance?.connectionStatus ?? null,
      }));

    const inUse = proxies.filter((p) => p.inUse).length;

    return {
      total: proxies.length,
      inUse,
      free: proxies.length - inUse,
      proxies,
      outsidePool,
    };
  }

  public async createProxy(instance: InstanceDto, data: ProxyDto) {
    if (!this.waMonitor.waInstances[instance.instanceName]) {
      throw new NotFoundException(`The "${instance.instanceName}" instance does not exist`);
    }

    if (!data?.enabled) {
      data.host = '';
      data.port = '';
      data.protocol = '';
      data.username = '';
      data.password = '';
    }

    if (data.host) {
      const testProxy = await this.testProxy(data);
      if (!testProxy) {
        throw new BadRequestException('Invalid proxy');
      }
    }

    return this.proxyService.create(instance, data);
  }

  public async findProxy(instance: InstanceDto) {
    if (!this.waMonitor.waInstances[instance.instanceName]) {
      throw new NotFoundException(`The "${instance.instanceName}" instance does not exist`);
    }

    return this.proxyService.find(instance);
  }

  public async testProxy(proxy: ProxyDto) {
    try {
      const serverIp = await axios.get('https://icanhazip.com/');
      const response = await axios.get('https://icanhazip.com/', {
        httpsAgent: makeProxyAgent(proxy),
      });

      const result = response?.data !== serverIp?.data;
      if (result) {
        logger.info('testProxy: proxy connection successful');
      } else {
        logger.warn("testProxy: proxy connection doesn't change the origin IP");
      }

      return result;
    } catch (error) {
      if (axios.isAxiosError(error)) {
        logger.error('testProxy error: axios error: ' + error.message);
      } else {
        logger.error('testProxy error: unexpected error: ' + error);
      }

      return false;
    }
  }
}
