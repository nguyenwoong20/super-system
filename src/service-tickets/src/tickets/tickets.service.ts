import {
  Injectable,
  NotFoundException,
  BadRequestException,
  Inject,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository, DataSource } from 'typeorm';
import { ClientKafka } from '@nestjs/microservices';
import { Ticket, TicketStatus } from './ticket.entity';
import { Event } from './event.entity';
import { BookTicketDto } from './dto/book-ticket.dto';

@Injectable()
export class TicketsService {
  constructor(
    @InjectRepository(Ticket)
    private readonly ticketRepo: Repository<Ticket>,
    @InjectRepository(Event)
    private readonly eventRepo: Repository<Event>,
    @Inject('KAFKA_SERVICE')
    private readonly kafkaClient: ClientKafka,
    private readonly dataSource: DataSource,
  ) {}

  async findAllEvents(): Promise<Event[]> {
    return this.eventRepo.find({
      where: { availableSeats: 1 },
      order: { eventDate: 'ASC' },
    });
  }

  async findEventById(id: string): Promise<Event> {
    const event = await this.eventRepo.findOne({ where: { id } });
    if (!event) throw new NotFoundException(`Event ${id} not found`);
    return event;
  }

  async findAvailableSeats(eventId: string): Promise<Ticket[]> {
    return this.ticketRepo.find({
      where: { eventId, status: TicketStatus.AVAILABLE },
      order: { seatNumber: 'ASC' },
    });
  }

  // ── Book a Ticket (transactional) ─────────────────────
  async bookTicket(dto: BookTicketDto, userId: string): Promise<Ticket> {
    // Use DB transaction to prevent double-booking race conditions
    return this.dataSource.transaction(async (manager) => {
      // Lock the ticket row for update
      const ticket = await manager
        .getRepository(Ticket)
        .createQueryBuilder('ticket')
        .setLock('pessimistic_write')
        .where('ticket.id = :id', { id: dto.ticketId })
        .getOne();

      if (!ticket) throw new NotFoundException('Ticket not found');
      if (ticket.status !== TicketStatus.AVAILABLE) {
        throw new BadRequestException('Ticket is no longer available');
      }

      // Mark as sold
      ticket.status = TicketStatus.SOLD;
      ticket.bookedByUserId = userId;
      const saved = await manager.save(ticket);

      // Decrement available seat count
      await manager
        .getRepository(Event)
        .decrement({ id: ticket.eventId }, 'availableSeats', 1);

      // 🔔 Publish Kafka event: ticket.booked
      // mail-service or payment-service can consume this
      await this.kafkaClient.emit('ticket.booked', {
        ticketId: saved.id,
        eventId: saved.eventId,
        userId,
        seatNumber: saved.seatNumber,
        price: saved.price,
        bookedAt: new Date(),
      });

      return saved;
    });
  }

  async findUserBookings(userId: string): Promise<Ticket[]> {
    return this.ticketRepo.find({
      where: { bookedByUserId: userId },
      relations: ['event'],
      order: { createdAt: 'DESC' },
    });
  }

  // ── Sync user data from Kafka event ──────────────────
  async syncUser(data: any): Promise<void> {
    // In a real system, you'd store a local copy of user data
    // for fast joins without cross-service HTTP calls
    console.log(`✅ Synced user: ${data.email} (${data.userId})`);
  }
}
