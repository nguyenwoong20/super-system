import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { ClientsModule, Transport } from '@nestjs/microservices';
import { TicketsController } from './tickets.controller';
import { TicketsService } from './tickets.service';
import { Ticket } from './ticket.entity';
import { Event } from './event.entity';

@Module({
  imports: [
    TypeOrmModule.forFeature([Ticket, Event]),

    ClientsModule.registerAsync([
      {
        name: 'KAFKA_SERVICE',
        imports: [ConfigModule],
        inject: [ConfigService],
        useFactory: (config: ConfigService) => ({
          transport: Transport.KAFKA,
          options: {
            client: {
              clientId: 'ticket-producer',
              brokers: (config.get<string>('KAFKA_BROKERS') ?? 'localhost:9092').split(','),
            },
          },
        }),
      },
    ]),
  ],
  providers: [TicketsService],
  controllers: [TicketsController],
})
export class TicketsModule {}
