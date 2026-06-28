import {
  Controller,
  Get,
  Post,
  Body,
  Param,
  UseGuards,
  Request,
  HttpCode,
  HttpStatus,
  ParseUUIDPipe,
} from '@nestjs/common';
import { AuthGuard } from '@nestjs/passport';
import { MessagePattern, Payload } from '@nestjs/microservices';
import { TicketsService } from './tickets.service';
import { BookTicketDto } from './dto/book-ticket.dto';

@Controller('tickets')
export class TicketsController {
  constructor(private readonly ticketsService: TicketsService) {}

  // ── HTTP Endpoints ────────────────────────────────────

  // GET /api/tickets/events — list all events
  @Get('events')
  async findAllEvents() {
    return this.ticketsService.findAllEvents();
  }

  // GET /api/tickets/events/:id — event detail
  @Get('events/:id')
  async findEvent(@Param('id', ParseUUIDPipe) id: string) {
    return this.ticketsService.findEventById(id);
  }

  // GET /api/tickets/events/:id/seats — available seats
  @Get('events/:id/seats')
  async findAvailableSeats(@Param('id', ParseUUIDPipe) id: string) {
    return this.ticketsService.findAvailableSeats(id);
  }

  // POST /api/tickets/book — book a ticket
  @Post('book')
  @HttpCode(HttpStatus.CREATED)
  @UseGuards(AuthGuard('jwt'))
  async bookTicket(@Body() dto: BookTicketDto, @Request() req) {
    return this.ticketsService.bookTicket(dto, req.user.userId);
  }

  // GET /api/tickets/my-bookings — user's bookings
  @Get('my-bookings')
  @UseGuards(AuthGuard('jwt'))
  async myBookings(@Request() req) {
    return this.ticketsService.findUserBookings(req.user.userId);
  }

  // GET /health
  @Get('health')
  health() {
    return { status: 'ok', service: 'ticket-service', timestamp: new Date() };
  }

  // ── Kafka Event Consumers ─────────────────────────────

  // Consumes: user.created (from auth-service)
  // Purpose: Sync user data locally for denormalization
  @MessagePattern('user.created')
  async handleUserCreated(@Payload() data: any) {
    console.log('📩 Kafka: user.created received', data);
    await this.ticketsService.syncUser(data);
  }
}
