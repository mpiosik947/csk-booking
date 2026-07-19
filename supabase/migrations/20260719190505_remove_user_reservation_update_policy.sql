-- Użytkownik tworzy rezerwacje przez INSERT, odczytuje je przez SELECT,
-- a anuluje wyłącznie przez SECURITY DEFINER RPC cancel_reservation.
-- Bezpośredni UPDATE własnej rezerwacji nie jest już potrzebny.
drop policy if exists "Users can update own reservations"
on public.reservations;
