import { IsUUID } from 'class-validator';

export class BookTicketDto {
  @IsUUID()
  ticketId: string;
}
