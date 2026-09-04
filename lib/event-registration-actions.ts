export type HandleFreedEventPlaceResult = {
  reserveFound: boolean;
  emailsSent: number;
  error: string;
};

export async function handleFreedEventPlace(
  eventId: string
): Promise<HandleFreedEventPlaceResult> {
  try {
    const response = await fetch("/api/send-event-reserve-promotion", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        eventId,
      }),
    });

    const data = await response.json().catch(() => null);

    if (!response.ok) {
      return {
        reserveFound: false,
        emailsSent: 0,
        error: "Nie udało się wysłać powiadomień do listy rezerwowej.",
      };
    }

    return {
      reserveFound: Boolean(data?.reserveFound),
      emailsSent: Number(data?.emailsSent ?? 0),
      error: "",
    };
  } catch {
    return {
      reserveFound: false,
      emailsSent: 0,
      error: "Wystąpił błąd podczas obsługi listy rezerwowej.",
    };
  }
}
